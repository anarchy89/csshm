// SPDX-License-Identifier: GPL-3.0-or-later

public enum ShellWordsError: Error, Equatable, CustomStringConvertible {
    case unbalancedQuote

    public var description: String { "unbalanced quote" }
}

public enum ShellWords {
    /// Splits a string into words the way a POSIX shell would: whitespace
    /// separates words, single quotes are literal, double quotes allow
    /// backslash escapes and a backslash outside quotes escapes one
    /// character. Nothing is expanded, so `~` and `$HOME` pass through.
    public static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case " ", "\t", "\n", "\r":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            case "'":
                inWord = true
                var closed = false
                while let q = iterator.next() {
                    if q == "'" { closed = true; break }
                    current.append(q)
                }
                guard closed else { throw ShellWordsError.unbalancedQuote }
            case "\"":
                inWord = true
                var closed = false
                while let q = iterator.next() {
                    if q == "\"" { closed = true; break }
                    if q == "\\" {
                        guard let escaped = iterator.next() else { throw ShellWordsError.unbalancedQuote }
                        if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                            current.append(escaped)
                        } else {
                            current.append("\\")
                            current.append(escaped)
                        }
                    } else {
                        current.append(q)
                    }
                }
                guard closed else { throw ShellWordsError.unbalancedQuote }
            case "\\":
                inWord = true
                if let escaped = iterator.next() { current.append(escaped) }
            default:
                inWord = true
                current.append(ch)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Quotes one word so that sh, bash, zsh and fish read it back unchanged.
    public static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    func replacingOccurrences(of target: Character, with replacement: String) -> String {
        var out = ""
        for ch in self {
            if ch == target { out += replacement } else { out.append(ch) }
        }
        return out
    }

    func replacingOccurrences(of target: String, with replacement: String) -> String {
        precondition(target.count == 1)
        return replacingOccurrences(of: target.first!, with: replacement)
    }
}
