// SPDX-License-Identifier: GPL-3.0-or-later

public enum ScreenSpecError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case noSuchScreen(Int, available: Int)

    public var description: String {
        switch self {
        case .invalid(let text):
            return "Bad screen [\(text)]: use a number (2), a range (2-4) or a list (1,3)"
        case .noSuchScreen(let n, let available):
            return available == 1
                ? "No such screen [\(n)]: only one screen is attached"
                : "No such screen [\(n)]: there are \(available) screens"
        }
    }
}

/// Which monitors a session uses. Screens are numbered from 1 in the order
/// macOS reports them, with 1 being the primary display.
public struct ScreenSpec: Equatable, Sendable, CustomStringConvertible {
    /// 1-based screen numbers, in the order given, without repeats.
    public let screens: [Int]

    public init(screens: [Int]) {
        self.screens = screens
    }

    /// Parses `3`, `2-4` (every screen from 2 to 4) or `1,3` and mixes of
    /// those. An empty string or `0` means the primary screen.
    public init(parsing text: String) throws {
        let trimmed = text.filter { !$0.isWhitespace }
        if trimmed.isEmpty || trimmed == "0" {
            self.screens = [1]
            return
        }
        var result: [Int] = []
        func add(_ n: Int) {
            if !result.contains(n) { result.append(n) }
        }
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count == 1 || ends.count == 2 else { throw ScreenSpecError.invalid(text) }
            let numbers = ends.map { Int($0) }
            guard !numbers.contains(nil), !ends.contains(where: { $0.contains("+") }) else {
                throw ScreenSpecError.invalid(text)
            }
            let first = numbers[0]!
            let last = numbers.count == 2 ? numbers[1]! : first
            guard first >= 1, last >= 1, abs(last - first) < 64 else { throw ScreenSpecError.invalid(text) }
            if first <= last {
                for n in first...last { add(n) }
            } else {
                for n in stride(from: first, through: last, by: -1) { add(n) }
            }
        }
        guard !result.isEmpty else { throw ScreenSpecError.invalid(text) }
        self.screens = result
    }

    /// Checks every screen number against the number of attached displays.
    public func validate(available: Int) throws {
        for n in screens where n > available {
            throw ScreenSpecError.noSuchScreen(n, available: available)
        }
    }

    public var description: String { screens.map(String.init).joined(separator: ",") }
}
