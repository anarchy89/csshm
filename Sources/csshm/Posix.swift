// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

let csshmVersion = "0.1.5"

/// Prints a message to standard error and exits.
func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("csshm: " + message + "\n").utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("csshm: " + message + "\n").utf8))
}

/// Writes all of `bytes` to a blocking descriptor. Returns false on failure.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            return false
        }
        offset += n
    }
    return true
}

@discardableResult
func writeAll(_ fd: Int32, _ text: String) -> Bool {
    writeAll(fd, Array(text.utf8))
}

func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

func setCloseOnExec(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
}

/// The terminal device attached to standard input, e.g. `/dev/ttys004`.
func controllingTTY() -> String? {
    guard let name = ttyname(0) else { return nil }
    return String(cString: name)
}

private func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in bytes.enumerated() { raw[index] = byte }
        raw[bytes.count] = 0
    }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// Creates a listening unix socket at `path`, readable only by the owner.
func listenUnix(at path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    unlink(path)
    let old = umask(0o077)
    let bound = withUnixAddress(path) { bind(fd, $0, $1) }
    umask(old)
    guard bound == 0, listen(fd, 256) == 0 else {
        close(fd)
        return nil
    }
    setNonBlocking(fd)
    setCloseOnExec(fd)
    return fd
}

func connectUnix(to path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard withUnixAddress(path, { connect(fd, $0, $1) }) == 0 else {
        close(fd)
        return nil
    }
    setCloseOnExec(fd)
    return fd
}

/// Starts a program with the given arguments. With `detached`, the program
/// gets its own session and no terminal, so it outlives this process's window.
func spawn(_ argv: [String], detached: Bool = false) -> (pid: pid_t, error: Int32) {
    var pid: pid_t = 0
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    defer { cArgs.forEach { free($0) } }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    // The child must not inherit ignored signals from us.
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGTSTP, SIGTTOU, SIGTTIN, SIGPIPE, SIGHUP, SIGTERM, SIGCHLD] {
        sigaddset(&defaults, sig)
    }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var flags = POSIX_SPAWN_SETSIGDEF
    if detached {
        flags |= POSIX_SPAWN_SETSID
        for fd in [Int32(0), 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0)
        }
    }
    posix_spawnattr_setflags(&attributes, Int16(flags))

    let result = posix_spawnp(&pid, argv[0], &actions, &attributes, cArgs, environ)
    return (pid, result)
}

/// Turns a `waitpid` status into a shell-style exit code.
func exitCode(fromWaitStatus status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}
