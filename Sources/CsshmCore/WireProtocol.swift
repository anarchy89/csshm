// SPDX-License-Identifier: GPL-3.0-or-later

public enum WireError: Error, Equatable {
    case unknownTag(UInt8)
    case malformed
    case tooLarge(Int)
}

/// Messages between the master and each host window's process. On the wire a
/// message is one tag byte, a 4-byte big-endian payload length, then the
/// payload.
public enum Message: Equatable, Sendable {
    /// Host process to master, first thing after connecting.
    case hello(id: UInt32, tty: String, pid: Int32)
    /// Master to host process: the command to run in the window. With
    /// `holdQuickFailure`, a command that fails within its first few seconds
    /// is treated as never having started, and the window is kept open.
    /// With `keepOpen`, the window is kept open however the command ends.
    case run(argv: [String], title: String, debug: Bool, holdQuickFailure: Bool, keepOpen: Bool = false)
    /// Master to host process: bytes to feed to the terminal as typed input.
    case input([UInt8])
    /// Host process to master: the command ended with an error and the
    /// window is being kept open to show it.
    case exited(status: Int32)
    /// Master to host process: end the command and exit.
    case quit

    static let maxPayload = 1 << 20

    private var tag: UInt8 {
        switch self {
        case .hello: return 1
        case .run: return 2
        case .input: return 3
        case .exited: return 4
        case .quit: return 5
        }
    }

    public func encoded() -> [UInt8] {
        var payload: [UInt8] = []
        switch self {
        case .hello(let id, let tty, let pid):
            Message.put(UInt32(id), into: &payload)
            Message.put(UInt32(bitPattern: pid), into: &payload)
            Message.put(tty, into: &payload)
        case .run(let argv, let title, let debug, let holdQuickFailure, let keepOpen):
            payload.append((debug ? 1 : 0) | (holdQuickFailure ? 2 : 0) | (keepOpen ? 4 : 0))
            Message.put(title, into: &payload)
            Message.put(UInt32(argv.count), into: &payload)
            for word in argv { Message.put(word, into: &payload) }
        case .input(let bytes):
            payload = bytes
        case .exited(let status):
            Message.put(UInt32(bitPattern: status), into: &payload)
        case .quit:
            break
        }
        var frame: [UInt8] = [tag]
        Message.put(UInt32(payload.count), into: &frame)
        frame += payload
        return frame
    }

    static func decode(tag: UInt8, payload: [UInt8]) throws -> Message {
        var reader = Reader(bytes: payload)
        switch tag {
        case 1:
            let id = try reader.uint32()
            let pid = Int32(bitPattern: try reader.uint32())
            let tty = try reader.string()
            return .hello(id: id, tty: tty, pid: pid)
        case 2:
            let flags = try reader.byte()
            let title = try reader.string()
            let count = Int(try reader.uint32())
            guard count <= payload.count else { throw WireError.malformed }
            var argv: [String] = []
            for _ in 0..<count { argv.append(try reader.string()) }
            return .run(argv: argv, title: title, debug: flags & 1 != 0, holdQuickFailure: flags & 2 != 0, keepOpen: flags & 4 != 0)
        case 3:
            return .input(payload)
        case 4:
            return .exited(status: Int32(bitPattern: try reader.uint32()))
        case 5:
            return .quit
        default:
            throw WireError.unknownTag(tag)
        }
    }

    private static func put(_ value: UInt32, into bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func put(_ text: String, into bytes: inout [UInt8]) {
        let utf8 = Array(text.utf8)
        put(UInt32(utf8.count), into: &bytes)
        bytes += utf8
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw WireError.malformed }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw WireError.malformed }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() throws -> String {
            let length = Int(try uint32())
            guard offset + length <= bytes.count else { throw WireError.malformed }
            defer { offset += length }
            return String(decoding: bytes[offset..<offset + length], as: UTF8.self)
        }
    }
}

/// Turns a byte stream, delivered in arbitrary pieces, back into messages.
public struct MessageDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) {
        buffer += bytes
    }

    public mutating func feed(_ bytes: ArraySlice<UInt8>) {
        buffer += bytes
    }

    /// The next complete message, or `nil` if more bytes are needed.
    public mutating func next() throws -> Message? {
        guard buffer.count >= 5 else { return nil }
        let length = buffer[1..<5].reduce(0) { $0 << 8 | Int($1) }
        guard length <= Message.maxPayload else { throw WireError.tooLarge(length) }
        guard buffer.count >= 5 + length else { return nil }
        let tag = buffer[0]
        let payload = Array(buffer[5..<5 + length])
        buffer.removeFirst(5 + length)
        return try Message.decode(tag: tag, payload: payload)
    }
}
