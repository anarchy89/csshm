// SPDX-License-Identifier: GPL-3.0-or-later

/// A rectangle in screen points, measured from the top-left of the primary
/// display with y increasing downwards (the convention Terminal.app's
/// `bounds` property uses).
public struct Rect: Equatable, Codable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts a rectangle measured the AppKit way (from the bottom-left of
    /// the primary display, y increasing upwards) to this type's convention.
    /// `primaryHeight` is the full height of the primary display.
    public init(bottomLeftX: Double, bottomLeftY: Double, width: Double, height: Double, primaryHeight: Double) {
        self.x = Int(bottomLeftX.rounded())
        self.y = Int((primaryHeight - (bottomLeftY + height)).rounded())
        self.width = Int(width.rounded(.down))
        self.height = Int(height.rounded(.down))
    }

    /// Cuts the rectangle into `count` equal columns, left to right.
    public func splitIntoColumns(_ count: Int) -> [Rect] {
        guard count > 1 else { return [self] }
        let each = width / count
        return (0..<count).map { Rect(x: x + $0 * each, y: y, width: each, height: height) }
    }

    public var right: Int { x + width }
    public var bottom: Int { y + height }
    public var centerX: Double { Double(x) + Double(width) / 2 }
    public var centerY: Double { Double(y) + Double(height) / 2 }
    public var area: Int { max(0, width) * max(0, height) }

    public var description: String { "{\(x), \(y), \(width)x\(height)}" }
}

/// A colour with 16-bit channels, the form Terminal.app scripting uses.
public struct RGB: Equatable, Codable, Sendable {
    public var red: UInt16
    public var green: UInt16
    public var blue: UInt16

    public init(_ red: UInt16, _ green: UInt16, _ blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Default colours for window state feedback.
public enum Palette {
    public static let masterBackground = RGB(38036, 0, 0)
    public static let masterForeground = RGB(65535, 65535, 65535)
    public static let disabledForeground = RGB(37779, 37779, 37779)
    public static let selectedBackground = RGB(17990, 35209, 53456)
}
