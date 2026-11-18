// SPDX-License-Identifier: GPL-3.0-or-later

public enum TomlValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([TomlValue])
    case table([String: TomlValue])
}

public struct TomlError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

/// A reader for the part of TOML that a settings file needs: `key = value`
/// lines, `[table]` and `[table.subtable]` headers, comments and values that
/// are strings, whole numbers, true/false or lists (which may span lines).
public enum Toml {
    public static func parse(_ text: String) throws -> [String: TomlValue] {
        // A file saved with Windows line endings: Swift reads each "\r\n"
        // as one character, which is neither "\r" nor "\n".
        var parser = Parser(characters: text.map { $0 == "\r\n" ? "\n" : $0 })
        return try parser.parseDocument()
    }

    private struct Parser {
        let characters: [Character]
        var position = 0
        var line = 1

        func fail(_ message: String) -> TomlError { TomlError(line: line, message: message) }

        var current: Character? { position < characters.count ? characters[position] : nil }

        mutating func advance() {
            if characters[position] == "\n" { line += 1 }
            position += 1
        }

        /// Skips spaces and tabs and a comment if one starts here.
        mutating func skipBlanks() {
            while let ch = current, ch == " " || ch == "\t" || ch == "\r" { advance() }
            if current == "#" {
                while let ch = current, ch != "\n" { _ = ch; advance() }
            }
        }

        /// Skips blanks, comments and line breaks.
        mutating func skipLines() {
            while true {
                skipBlanks()
                guard current == "\n" else { return }
                advance()
            }
        }

        mutating func parseDocument() throws -> [String: TomlValue] {
            var root: [String: TomlValue] = [:]
            var path: [String] = []
            while true {
                skipLines()
                guard let ch = current else { break }
                if ch == "[" {
                    advance()
                    path = []
                    while true {
                        skipBlanks()
                        path.append(try parseKey())
                        skipBlanks()
                        if current == "." { advance(); continue }
                        guard current == "]" else { throw fail("expected ] to end the section name") }
                        advance()
                        break
                    }
                    try Parser.insert(.table([:]), at: path, into: &root, replacingTables: false, fail: fail)
                } else {
                    let key = try parseKey()
                    skipBlanks()
                    guard current == "=" else { throw fail("expected = after \(key)") }
                    advance()
                    skipBlanks()
                    let value = try parseValue()
                    try Parser.insert(value, at: path + [key], into: &root, replacingTables: false, fail: fail)
                }
                skipBlanks()
                guard current == nil || current == "\n" else { throw fail("unexpected text at the end of the line") }
            }
            return root
        }

        static func insert(_ value: TomlValue, at path: [String], into table: inout [String: TomlValue],
                           replacingTables: Bool, fail: (String) -> TomlError) throws {
            let key = path[0]
            if path.count == 1 {
                if let existing = table[key] {
                    // Naming a section twice or after its subsection, is allowed.
                    if case .table = existing, case .table = value { return }
                    throw fail("\(key) is set twice")
                }
                table[key] = value
                return
            }
            var inner: [String: TomlValue] = [:]
            if let existing = table[key] {
                guard case .table(let t) = existing else { throw fail("\(key) is not a section") }
                inner = t
            }
            try insert(value, at: Array(path.dropFirst()), into: &inner, replacingTables: replacingTables, fail: fail)
            table[key] = .table(inner)
        }

        mutating func parseKey() throws -> String {
            if current == "\"" || current == "'" {
                guard case .string(let text) = try parseValue() else { throw fail("bad name") }
                return text
            }
            var key = ""
            while let ch = current, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                key.append(ch)
                advance()
            }
            guard !key.isEmpty else { throw fail("expected a setting name") }
            return key
        }

        mutating func parseValue() throws -> TomlValue {
            guard let ch = current else { throw fail("expected a value") }
            switch ch {
            case "\"":
                advance()
                var text = ""
                while true {
                    guard let c = current, c != "\n" else { throw fail("a string is missing its closing quote") }
                    advance()
                    if c == "\"" { return .string(text) }
                    if c == "\\" {
                        guard let escaped = current else { throw fail("a string is missing its closing quote") }
                        advance()
                        switch escaped {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "\"", "\\": text.append(escaped)
                        default: throw fail("unknown escape \\\(escaped) in a string; use '...' for text with backslashes")
                        }
                    } else {
                        text.append(c)
                    }
                }
            case "'":
                advance()
                var text = ""
                while true {
                    guard let c = current, c != "\n" else { throw fail("a string is missing its closing quote") }
                    advance()
                    if c == "'" { return .string(text) }
                    text.append(c)
                }
            case "[":
                advance()
                var items: [TomlValue] = []
                while true {
                    skipLines()
                    if current == "]" { advance(); return .array(items) }
                    items.append(try parseValue())
                    skipLines()
                    if current == "," { advance(); continue }
                    guard current == "]" else { throw fail("expected a comma or ] in a list") }
                }
            default:
                var word = ""
                while let c = current, c.isLetter || c.isNumber || c == "-" || c == "+" || c == "_" {
                    word.append(c)
                    advance()
                }
                if word == "true" { return .boolean(true) }
                if word == "false" { return .boolean(false) }
                if let number = Int(word.filter { $0 != "_" }) { return .integer(number) }
                throw fail(word.isEmpty ? "expected a value" : "\(word) is not a value; text needs quotes")
            }
        }
    }
}
