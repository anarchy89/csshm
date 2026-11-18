// SPDX-License-Identifier: GPL-3.0-or-later

/// Interprets what is typed into the master window. In input mode the bytes
/// go to the hosts; the action key opens a menu of single-key commands, some
/// of which lead to further modes. The machine only decides what the keys
/// mean and reports actions; it does not touch windows or sockets.
public struct ControlMachine: Sendable {
    public enum Mode: Equatable, Sendable {
        case input, action, enable, sendText, sort, addHost, dumpScrollback, moveScreen
    }

    public enum TextKind: Equatable, Sendable {
        case hostname, connection, windowID, slaveID
    }

    public enum SortKind: Equatable, Sendable {
        case host, id
    }

    public enum Action: Equatable, Sendable {
        /// Bytes for every enabled host.
        case send([UInt8])
        case modeChanged(Mode)
        /// The text being typed in a prompt changed.
        case lineChanged
        case retile
        case gridMore
        case gridLess
        case fontSmaller
        case fontLarger
        case addHost(String)
        /// Run every host whose session has ended again.
        case rerunEnded
        case selectMove(dx: Int, dy: Int)
        case enableSelected
        case disableSelected
        case toggleSelected
        case onlySelected(zoom: Bool)
        case enableAll
        case toggleAll
        case enableNext
        case minimise
        case hide
        /// Hide the host windows and minimise the master.
        case tidy
        case sendText(TextKind)
        case sort(SortKind)
        case dumpScrollback(String)
        case moveToScreen(String)
        case quit
        case beep
    }

    public let actionKey: UInt8
    public private(set) var mode: Mode = .input
    private var lineBytes: [UInt8] = []
    /// The start of an escape sequence whose end has not arrived yet.
    private var pending: [UInt8] = []

    public init(actionKey: UInt8 = 0x01) {
        self.actionKey = actionKey
    }

    /// The text typed so far in a prompt mode.
    public var line: String { String(decoding: lineBytes, as: UTF8.self) }

    /// True while the machine is holding back the start of an escape
    /// sequence. If no more input arrives shortly, call `flush()`.
    public var hasPending: Bool { !pending.isEmpty }

    public mutating func feed(_ bytes: [UInt8]) -> [Action] {
        process(bytes, final: false)
    }

    /// Treats held-back bytes as complete: a lone Esc was really Esc.
    public mutating func flush() -> [Action] {
        process([], final: true)
    }

    private enum Token {
        case byte(UInt8)
        case escape
        case arrow(dx: Int, dy: Int)
        case unknownSequence
    }

    private static let esc: UInt8 = 0x1b

    private static func arrow(_ final: UInt8) -> Token? {
        switch final {
        case 0x41: return .arrow(dx: 0, dy: -1)  // A: up
        case 0x42: return .arrow(dx: 0, dy: 1)   // B: down
        case 0x43: return .arrow(dx: 1, dy: 0)   // C: right
        case 0x44: return .arrow(dx: -1, dy: 0)  // D: left
        default: return nil
        }
    }

    private mutating func process(_ bytes: [UInt8], final: Bool) -> [Action] {
        let data = pending + bytes
        pending = []
        var actions: [Action] = []
        var outgoing: [UInt8] = []
        var i = 0

        func flushOutgoing(_ actions: inout [Action], _ outgoing: inout [UInt8]) {
            if !outgoing.isEmpty {
                actions.append(.send(outgoing))
                outgoing = []
            }
        }

        scan: while i < data.count {
            let byte = data[i]
            if mode == .input {
                if byte == actionKey {
                    flushOutgoing(&actions, &outgoing)
                    setMode(.action, &actions)
                    i += 1
                    continue
                }
                if byte == ControlMachine.esc {
                    // Arrow keys arrive as ESC [ A..D. Hosts running full-screen
                    // programs expect the ESC O A..D form, so convert them.
                    if i + 1 >= data.count {
                        if !final { pending = Array(data[i...]); break scan }
                    } else if data[i + 1] == 0x5b {
                        if i + 2 >= data.count {
                            if !final { pending = Array(data[i...]); break scan }
                        } else if (0x41...0x44).contains(data[i + 2]) {
                            outgoing += [ControlMachine.esc, 0x4f, data[i + 2]]
                            i += 3
                            continue
                        }
                    }
                }
                outgoing.append(byte)
                i += 1
                continue
            }

            // Menu and prompt modes work on whole keys.
            var token = Token.byte(byte)
            if byte == ControlMachine.esc {
                token = .escape
                if i + 1 >= data.count {
                    if !final { pending = Array(data[i...]); break scan }
                    i += 1
                } else if data[i + 1] == 0x4f {
                    if i + 2 >= data.count {
                        if !final { pending = Array(data[i...]); break scan }
                        i += 1
                    } else if let arrow = ControlMachine.arrow(data[i + 2]) {
                        token = arrow
                        i += 3
                    } else {
                        i += 1
                    }
                } else if data[i + 1] == 0x5b {
                    var j = i + 2
                    while j < data.count, (0x20...0x3f).contains(data[j]) { j += 1 }
                    if j >= data.count {
                        if !final { pending = Array(data[i...]); break scan }
                        i += 1
                    } else {
                        token = (j == i + 2 ? ControlMachine.arrow(data[j]) : nil) ?? .unknownSequence
                        i = j + 1
                    }
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
            handle(token, &actions)
        }
        flushOutgoing(&actions, &outgoing)
        return actions
    }

    private mutating func setMode(_ newMode: Mode, _ actions: inout [Action]) {
        mode = newMode
        lineBytes = []
        actions.append(.modeChanged(newMode))
    }

    private mutating func handle(_ token: Token, _ actions: inout [Action]) {
        switch mode {
        case .input:
            break
        case .action:
            handleAction(token, &actions)
        case .enable:
            handleEnable(token, &actions)
        case .sendText:
            handleChoice(token, &actions) { key in
                switch key {
                case "h": return .sendText(.hostname)
                case "c": return .sendText(.connection)
                case "i": return .sendText(.windowID)
                case "s": return .sendText(.slaveID)
                default: return nil
                }
            }
        case .sort:
            handleChoice(token, &actions) { key in
                switch key {
                case "h": return .sort(.host)
                case "i": return .sort(.id)
                default: return nil
                }
            }
        case .addHost, .dumpScrollback, .moveScreen:
            handleLine(token, &actions)
        }
    }

    private mutating func handleAction(_ token: Token, _ actions: inout [Action]) {
        guard case .byte(let byte) = token else {
            if case .escape = token {
                setMode(.input, &actions)
            } else {
                actions.append(.beep)
            }
            return
        }
        if byte == actionKey {
            actions.append(.send([actionKey]))
            setMode(.input, &actions)
            return
        }
        // Actions that run once and return to typing.
        func once(_ action: Action, _ actions: inout [Action]) {
            actions.append(action)
            setMode(.input, &actions)
        }
        switch byte {
        case UInt8(ascii: "r"): once(.retile, &actions)
        case UInt8(ascii: "a"): once(.rerunEnded, &actions)
        case UInt8(ascii: "n"): once(.enableAll, &actions)
        case UInt8(ascii: "t"): once(.toggleAll, &actions)
        case UInt8(ascii: " "): once(.enableNext, &actions)
        case UInt8(ascii: "m"): once(.minimise, &actions)
        case UInt8(ascii: "h"): once(.hide, &actions)
        case 0x08: once(.tidy, &actions)
        case UInt8(ascii: "x"): actions.append(.quit)
        // The grid and font keys stay in the menu so they can be pressed repeatedly.
        case UInt8(ascii: "g"): actions.append(.gridMore)
        case UInt8(ascii: "G"): actions.append(.gridLess)
        case UInt8(ascii: "f"): actions.append(.fontSmaller)
        case UInt8(ascii: "F"): actions.append(.fontLarger)
        case UInt8(ascii: "c"): setMode(.addHost, &actions)
        case UInt8(ascii: "e"): setMode(.enable, &actions)
        case UInt8(ascii: "s"): setMode(.sendText, &actions)
        case UInt8(ascii: "o"): setMode(.sort, &actions)
        case UInt8(ascii: "d"): setMode(.dumpScrollback, &actions)
        case UInt8(ascii: "v"): setMode(.moveScreen, &actions)
        default: actions.append(.beep)
        }
    }

    private mutating func handleEnable(_ token: Token, _ actions: inout [Action]) {
        switch token {
        case .arrow(let dx, let dy):
            actions.append(.selectMove(dx: dx, dy: dy))
        case .escape:
            setMode(.input, &actions)
        case .unknownSequence:
            actions.append(.beep)
        case .byte(let byte):
            switch byte {
            case UInt8(ascii: "h"): actions.append(.selectMove(dx: -1, dy: 0))
            case UInt8(ascii: "l"): actions.append(.selectMove(dx: 1, dy: 0))
            case UInt8(ascii: "k"): actions.append(.selectMove(dx: 0, dy: -1))
            case UInt8(ascii: "j"): actions.append(.selectMove(dx: 0, dy: 1))
            case UInt8(ascii: "e"): actions.append(.enableSelected)
            case UInt8(ascii: "d"): actions.append(.disableSelected)
            case UInt8(ascii: "t"): actions.append(.toggleSelected)
            case UInt8(ascii: "o"):
                actions.append(.onlySelected(zoom: false))
                setMode(.input, &actions)
            case UInt8(ascii: "O"):
                actions.append(.onlySelected(zoom: true))
                setMode(.input, &actions)
            case 0x0d, 0x0a:
                setMode(.input, &actions)
            default:
                actions.append(.beep)
            }
        }
    }

    private mutating func handleChoice(_ token: Token, _ actions: inout [Action], _ choose: (Character) -> Action?) {
        switch token {
        case .escape:
            setMode(.input, &actions)
        case .byte(let byte):
            if let action = choose(Character(UnicodeScalar(byte))) {
                actions.append(action)
                setMode(.input, &actions)
            } else {
                actions.append(.beep)
            }
        default:
            actions.append(.beep)
        }
    }

    private mutating func handleLine(_ token: Token, _ actions: inout [Action]) {
        guard case .byte(let byte) = token else {
            if case .escape = token {
                setMode(.input, &actions)
            } else {
                actions.append(.beep)
            }
            return
        }
        switch byte {
        case 0x0d, 0x0a:
            let text = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            switch mode {
            case .addHost:
                if !text.isEmpty { actions.append(.addHost(text)) }
            case .dumpScrollback:
                actions.append(.dumpScrollback(text))
            case .moveScreen:
                if !text.isEmpty { actions.append(.moveToScreen(text)) }
            default:
                break
            }
            setMode(.input, &actions)
        case 0x03:
            setMode(.input, &actions)
        case 0x7f, 0x08:
            // Remove one whole character, which may be several UTF-8 bytes.
            while let last = lineBytes.popLast() {
                if last & 0xc0 != 0x80 { break }
            }
            actions.append(.lineChanged)
        case 0x15:
            lineBytes = []
            actions.append(.lineChanged)
        default:
            if byte >= 0x20 {
                lineBytes.append(byte)
                actions.append(.lineChanged)
            } else {
                actions.append(.beep)
            }
        }
    }
}
