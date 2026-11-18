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

/// Part of one monitor that the windows are kept to (`--bounds`).
///
/// The corners are in points measured from the top-left corner of that
/// monitor, whatever its position among the others: `2:0,30-1720,1400` is
/// monitor 2 from 0,30 to 1720,1400.
public struct ScreenBounds: Equatable, Codable, Sendable, CustomStringConvertible {
    /// 1-based monitor number.
    public var screen: Int
    public var x1: Int
    public var y1: Int
    public var x2: Int
    public var y2: Int

    /// The smallest area worth laying windows out in.
    public static let minimumSide = 200

    public init(parsing text: String) throws {
        let bad = ConfigError("Bad bounds [\(text)]: use SCREEN:X1,Y1-X2,Y2, for example 2:0,30-1720,1400")
        let trimmed = text.filter { !$0.isWhitespace }
        let halves = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2, let screen = Int(halves[0]), screen >= 1 else { throw bad }
        let corners = halves[1].split(separator: "-", omittingEmptySubsequences: false)
        guard corners.count == 2 else { throw bad }
        var numbers: [Int] = []
        for corner in corners {
            let pair = corner.split(separator: ",", omittingEmptySubsequences: false)
            guard pair.count == 2, let x = Int(pair[0]), let y = Int(pair[1]),
                  !corner.contains("+") else { throw bad }
            numbers += [x, y]
        }
        guard numbers[2] - numbers[0] >= ScreenBounds.minimumSide, numbers[3] - numbers[1] >= ScreenBounds.minimumSide else {
            throw ConfigError("Bad bounds [\(text)]: the area must be at least \(ScreenBounds.minimumSide) points wide and high, with the top-left corner first")
        }
        self.screen = screen
        (x1, y1, x2, y2) = (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    public var description: String { "\(screen):\(x1),\(y1)-\(x2),\(y2)" }

    /// The area in the coordinates the rest of csshm uses, given the
    /// monitor's full rectangle.
    public func rect(in frame: Rect) -> Rect {
        Rect(x: frame.x + x1, y: frame.y + y1, width: x2 - x1, height: y2 - y1)
    }

    /// Checks that the area lies inside what is free on its monitor:
    /// `usable` is the monitor without the menu bar and the Dock.
    public func check(frame: Rect, usable: Rect) throws {
        let r = rect(in: frame)
        guard r.x >= usable.x, r.y >= usable.y, r.right <= usable.right, r.bottom <= usable.bottom else {
            throw ConfigError("--bounds \(self) does not fit: monitor \(screen) is free from "
                + "\(usable.x - frame.x),\(usable.y - frame.y) to \(usable.right - frame.x),\(usable.bottom - frame.y)")
        }
    }

    /// The part of the area that is free on its monitor now. During a
    /// session the menu bar or the Dock can appear inside an area that was
    /// accepted at the start, so then it is trimmed, not refused. `nil`
    /// when too little is left to use.
    public func limited(to usable: Rect, frame: Rect) -> Rect? {
        let r = rect(in: frame)
        let x = max(r.x, usable.x), y = max(r.y, usable.y)
        let right = min(r.right, usable.right), bottom = min(r.bottom, usable.bottom)
        guard right - x >= ScreenBounds.minimumSide, bottom - y >= ScreenBounds.minimumSide else { return nil }
        return Rect(x: x, y: y, width: right - x, height: bottom - y)
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
