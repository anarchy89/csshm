// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

/// The process in each host window. It asks the master what to run, starts
/// it on this terminal, and from then on feeds every byte the master sends
/// into the terminal's input queue, where the command reads it as typing.
enum Slave {
    /// TIOCSTI: "simulate terminal input".
    private static let injectRequest: UInt = 0x8001_7472

    private static let lock = NSLock()
    private static var quitRequested = false
    private static var ended = false

    static func run(session: String, id: Int) -> Never {
        let socketPath = session + "/sock"
        var socketFD: Int32 = -1
        for _ in 0..<50 {
            if let fd = connectUnix(to: socketPath) {
                socketFD = fd
                break
            }
            usleep(100_000)
        }
        guard socketFD >= 0 else { die("cannot reach the master window (\(socketPath))") }
        guard let tty = controllingTTY() else { die("this window has no terminal") }

        writeAll(socketFD, Message.hello(id: UInt32(id), tty: tty, pid: getpid()).encoded())

        var decoder = MessageDecoder()
        guard case .run(let argv, let title, let debug)? = nextMessage(socketFD, &decoder), !argv.isEmpty else {
            die("the master window went away before starting this session")
        }

        // Start with a clean window: the launch command typed into the shell is gone.
        writeAll(1, "\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}]0;\(title)\u{07}")
        if debug {
            writeAll(1, "csshm: \(argv.map(ShellWords.quote).joined(separator: " "))\r\n")
        }

        let child = spawn(argv)
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
        signal(SIGTTOU, SIG_IGN)
        signal(SIGTTIN, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        if child.error != 0 {
            writeAll(2, "csshm: cannot run \(argv[0]): \(String(cString: strerror(child.error)))\r\n")
            // Report it from another thread so this one can still hear "quit".
            Thread.detachNewThread { finish(code: 255, socketFD: socketFD) }
        } else {
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
                finish(code: exitCode(fromWaitStatus: status), socketFD: socketFD)
            }
        }

        var warned = false
        while let message = nextMessage(socketFD, &decoder) {
            switch message {
            case .input(let bytes):
                lock.lock()
                let stopped = ended
                lock.unlock()
                if stopped { continue }
                for (index, byte) in bytes.enumerated() {
                    if index % 64 == 0 { waitForInputRoom() }
                    var c = CChar(bitPattern: byte)
                    if ioctl(0, injectRequest, &c) != 0 && !warned {
                        warned = true
                        writeAll(2, "\r\ncsshm: cannot type into this terminal: \(String(cString: strerror(errno)))\r\n")
                    }
                }
            case .quit:
                lock.lock()
                quitRequested = true
                let alreadyEnded = ended
                lock.unlock()
                // A failed session is only waiting for Enter; there is nothing to stop.
                if alreadyEnded || child.error != 0 { exit(0) }
                kill(child.pid, SIGHUP)
                Thread.detachNewThread {
                    sleep(2)
                    kill(child.pid, SIGKILL)
                }
            default:
                break
            }
        }
        // The master has gone. Carry on as an ordinary session until the
        // command ends; the waiting thread exits the process then.
        while true { pause() }
    }

    /// FIONREAD: how many typed bytes the terminal is holding, unread.
    private static let pendingInputRequest: UInt = 0x4004_667f

    /// The kernel keeps only about a thousand unread input bytes per terminal
    /// and silently drops the rest. A large paste arrives faster than the
    /// command reads it, so pause while the queue is filling up. The wait is
    /// bounded in case nothing is reading at all.
    private static func waitForInputRoom() {
        for _ in 0..<400 {
            var pending: Int32 = 0
            if ioctl(0, pendingInputRequest, &pending) != 0 || pending < 256 { return }
            usleep(2_000)
        }
    }

    private static func nextMessage(_ fd: Int32, _ decoder: inout MessageDecoder) -> Message? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let message = try? decoder.next() { return message }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            decoder.feed(buffer[0..<n])
        }
    }

    /// Called once the command has ended. A failure from ssh itself (status
    /// 255: could not connect, connection lost) keeps the window open so the
    /// message can be read; anything else just exits.
    private static func finish(code: Int32, socketFD: Int32) -> Never {
        lock.lock()
        let quit = quitRequested
        ended = true
        lock.unlock()
        if quit || code != 255 {
            exit(code)
        }
        writeAll(socketFD, Message.exited(status: code).encoded())
        writeAll(1, "\r\n[csshm: this session ended with an error. Press Enter here to close the window.]\r\n")
        usleep(200_000)
        tcflush(0, TCIFLUSH)
        var byte: UInt8 = 0
        while true {
            let n = read(0, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 || byte == 0x0a || byte == 0x0d { break }
        }
        exit(code)
    }
}
