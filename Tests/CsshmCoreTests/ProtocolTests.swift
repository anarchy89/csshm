// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CsshmCore

final class WireProtocolTests: XCTestCase {
    let samples: [Message] = [
        .hello(id: 7, tty: "/dev/ttys012", pid: 4242),
        .run(argv: ["ssh", "-o", "User name=x", "-l", "ubuntu", "10.0.0.1", ""], title: "csshm - 10.0.0.1", debug: true, holdQuickFailure: false),
        .run(argv: [], title: "", debug: false, holdQuickFailure: false),
        .run(argv: ["docker", "exec", "-it", "web", "sh"], title: "csshm - web", debug: false, holdQuickFailure: true),
        .run(argv: ["x"], title: "t", debug: true, holdQuickFailure: true),
        .run(argv: ["ssh", "h", "uptime"], title: "t", debug: false, holdQuickFailure: false, keepOpen: true),
        .run(argv: ["x"], title: "t", debug: true, holdQuickFailure: true, keepOpen: true),
        .run(argv: ["ssh", "i-0518"], title: "t", debug: false, holdQuickFailure: false, environment: ["AWS_PROFILE=prod", "EMPTY=", "X=a=b c"]),
        .input(Array("ls -la\r".utf8)),
        .input([]),
        .input([0, 1, 255, 0x1b]),
        .exited(status: 255),
        .exited(status: -1),
        .quit,
    ]

    func testRoundTrip() throws {
        for message in samples {
            var decoder = MessageDecoder()
            decoder.feed(message.encoded())
            XCTAssertEqual(try decoder.next(), message)
            XCTAssertNil(try decoder.next())
        }
    }

    func testStreamSplitAtEveryByte() throws {
        let stream = samples.flatMap { $0.encoded() }
        var decoder = MessageDecoder()
        var decoded: [Message] = []
        for byte in stream {
            decoder.feed([byte])
            while let message = try decoder.next() { decoded.append(message) }
        }
        XCTAssertEqual(decoded, samples)
    }

    func testRejectsGarbage() {
        var unknown = MessageDecoder()
        unknown.feed([99, 0, 0, 0, 0])
        XCTAssertThrowsError(try unknown.next()) { XCTAssertEqual($0 as? WireError, .unknownTag(99)) }

        var huge = MessageDecoder()
        huge.feed([3, 0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try huge.next())

        var short = MessageDecoder()
        short.feed([1, 0, 0, 0, 2, 0, 0])
        XCTAssertThrowsError(try short.next()) { XCTAssertEqual($0 as? WireError, .malformed) }
    }
}

final class ControlMachineTests: XCTestCase {
    typealias Action = ControlMachine.Action

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testPlainTypingIsBroadcast() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("uptime\r")), [.send(bytes("uptime\r"))])
        // Ctrl-C and Ctrl-Z are ordinary bytes for the hosts.
        XCTAssertEqual(machine.feed([0x03, 0x1a]), [.send([0x03, 0x1a])])
    }

    func testArrowKeysAreConverted() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("a\u{1b}[Ab\u{1b}[D")), [.send(bytes("a\u{1b}OAb\u{1b}OD"))])
        // Other sequences pass through untouched.
        XCTAssertEqual(machine.feed(bytes("\u{1b}[3~\u{1b}x")), [.send(bytes("\u{1b}[3~\u{1b}x"))])
    }

    /// The csshX bug: a sequence split across two reads was not converted.
    func testArrowKeySplitAcrossReads() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed([0x1b]), [])
        XCTAssertTrue(machine.hasPending)
        XCTAssertEqual(machine.feed(bytes("[")), [])
        XCTAssertEqual(machine.feed(bytes("B")), [.send(bytes("\u{1b}OB"))])
        XCTAssertFalse(machine.hasPending)
    }

    func testLoneEscapeIsSentAfterFlush() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed([0x1b]), [])
        XCTAssertEqual(machine.flush(), [.send([0x1b])])
        XCTAssertEqual(machine.flush(), [])
    }

    func testActionKeyTwiceSendsItOnce() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed([0x01, 0x01]), [.modeChanged(.action), .send([0x01]), .modeChanged(.input)])
    }

    func testRetileAndReturnToTyping() {
        var machine = ControlMachine()
        XCTAssertEqual(
            machine.feed(bytes("ab\u{01}rcd")),
            [.send(bytes("ab")), .modeChanged(.action), .retile, .modeChanged(.input), .send(bytes("cd"))])
    }

    func testGridKeysRepeat() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("\u{01}ggG")), [.modeChanged(.action), .gridMore, .gridMore, .gridLess])
        XCTAssertEqual(machine.mode, .action)
        XCTAssertEqual(machine.feed([0x1b]), [])
        XCTAssertEqual(machine.flush(), [.modeChanged(.input)])
    }

    func testFontKeysRepeat() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("\u{01}ffF")), [.modeChanged(.action), .fontSmaller, .fontSmaller, .fontLarger])
        XCTAssertEqual(machine.mode, .action)
    }

    func testSingleKeyActions() {
        let table: [(String, Action)] = [
            ("n", .enableAll), ("t", .toggleAll), (" ", .enableNext), ("m", .minimise),
            ("h", .hide), ("\u{08}", .tidy),
        ]
        for (key, action) in table {
            var machine = ControlMachine()
            XCTAssertEqual(machine.feed(bytes("\u{01}" + key)), [.modeChanged(.action), action, .modeChanged(.input)], key)
        }
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("\u{01}x")), [.modeChanged(.action), .quit])
    }

    func testUnknownKeyBeepsAndStaysInMenu() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("\u{01}q\u{1b}[A")), [.modeChanged(.action), .beep, .beep])
        XCTAssertEqual(machine.mode, .action)
    }

    func testEnableMode() {
        var machine = ControlMachine()
        XCTAssertEqual(
            machine.feed(bytes("\u{01}el\u{1b}[Bkdte")),
            [.modeChanged(.action), .modeChanged(.enable),
             .selectMove(dx: 1, dy: 0), .selectMove(dx: 0, dy: 1), .selectMove(dx: 0, dy: -1),
             .disableSelected, .toggleSelected, .enableSelected])
        XCTAssertEqual(machine.feed(bytes("O")), [.onlySelected(zoom: true), .modeChanged(.input)])

        var other = ControlMachine()
        XCTAssertEqual(other.feed(bytes("\u{01}eo")), [.modeChanged(.action), .modeChanged(.enable), .onlySelected(zoom: false), .modeChanged(.input)])
        var enter = ControlMachine()
        XCTAssertEqual(enter.feed(bytes("\u{01}e\r")), [.modeChanged(.action), .modeChanged(.enable), .modeChanged(.input)])
    }

    func testSendTextAndSort() {
        var machine = ControlMachine()
        XCTAssertEqual(machine.feed(bytes("\u{01}sh")), [.modeChanged(.action), .modeChanged(.sendText), .sendText(.hostname), .modeChanged(.input)])
        XCTAssertEqual(machine.feed(bytes("\u{01}sc")), [.modeChanged(.action), .modeChanged(.sendText), .sendText(.connection), .modeChanged(.input)])
        XCTAssertEqual(machine.feed(bytes("\u{01}oh")), [.modeChanged(.action), .modeChanged(.sort), .sort(.host), .modeChanged(.input)])
        XCTAssertEqual(machine.feed(bytes("\u{01}oz")), [.modeChanged(.action), .modeChanged(.sort), .beep])
    }

    func testAddHostPromptWithEditing() {
        var machine = ControlMachine()
        _ = machine.feed(bytes("\u{01}c"))
        XCTAssertEqual(machine.mode, .addHost)
        _ = machine.feed(bytes("web9x"))
        XCTAssertEqual(machine.line, "web9x")
        XCTAssertEqual(machine.feed([0x7f]), [.lineChanged])
        XCTAssertEqual(machine.line, "web9")
        XCTAssertEqual(machine.feed(bytes("\rls")), [.addHost("web9"), .modeChanged(.input), .send(bytes("ls"))])
    }

    func testPromptCancelAndEmpty() {
        var machine = ControlMachine()
        _ = machine.feed(bytes("\u{01}cabc"))
        XCTAssertEqual(machine.feed([0x1b]), [])
        XCTAssertEqual(machine.flush(), [.modeChanged(.input)])
        XCTAssertEqual(machine.feed(bytes("\u{01}c\r")), [.modeChanged(.action), .modeChanged(.addHost), .modeChanged(.input)])
    }

    func testBackspaceRemovesAWholeCharacter() {
        var machine = ControlMachine()
        _ = machine.feed(bytes("\u{01}caé"))
        XCTAssertEqual(machine.line, "aé")
        _ = machine.feed([0x7f])
        XCTAssertEqual(machine.line, "a")
    }

    func testMoveScreenAndDumpPrompts() {
        var machine = ControlMachine()
        XCTAssertEqual(
            machine.feed(bytes("\u{01}v2-3\r")),
            [.modeChanged(.action), .modeChanged(.moveScreen), .lineChanged, .lineChanged, .lineChanged, .moveToScreen("2-3"), .modeChanged(.input)])
        // An empty name means the default file name.
        XCTAssertEqual(machine.feed(bytes("\u{01}d\r")), [.modeChanged(.action), .modeChanged(.dumpScrollback), .dumpScrollback(""), .modeChanged(.input)])
    }

    func testCustomActionKey() {
        var machine = ControlMachine(actionKey: 0x1a)
        XCTAssertEqual(machine.feed([0x01, 0x1a, UInt8(ascii: "r")]), [.send([0x01]), .modeChanged(.action), .retile, .modeChanged(.input)])
    }
}
