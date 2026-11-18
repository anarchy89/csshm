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

    /// The rectangle as left, bottom, right and top edges measured the AppKit
    /// way, upwards from the bottom-left of the primary display. This is the
    /// form Terminal's `frame` property takes.
    public func bottomLeftEdges(primaryHeight: Int) -> [Int] {
        [x, primaryHeight - bottom, right, primaryHeight - y]
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

/// Keeps windows clear of the Dock on the monitor the Dock is really on.
///
/// The Dock can be called to another monitor by resting the pointer at that
/// monitor's edge. macOS then goes on reporting the Dock's space on the
/// monitor it was on before: the usable area there stays short and the
/// monitor that now has the Dock looks completely free. Windows placed on
/// that basis end up underneath the Dock.
///
/// The strip on the monitor the Dock left cannot simply be handed back.
/// Terminal goes by the same out-of-date report: it shortens a window that
/// is taller than the area above the strip and moves up a window whose
/// title bar would be inside it. A window that only reaches down into the
/// strip is left alone, so the strip is reported as `spare` for the grid to
/// use when its windows meet those two conditions.
public enum DockSpace {
    /// What is needed to work out how thick the Dock is on another monitor.
    ///
    /// The Dock keeps its icons at the size set in System Settings while they
    /// fit along the monitor's edge. On a shorter edge it shrinks them all
    /// and gets thinner. macOS only reports the thickness for the monitor the
    /// Dock was on before and that figure is not updated when the icon size
    /// is changed while the Dock is away, so the thickness on the monitor it
    /// moved to is worked out from the icon size alone.
    ///
    /// The numbers come from measuring one Dock of 25 icons at icon sizes
    /// 16, 30, 64 and 72 on monitors 3440, 1920, 1728 and 1440 points wide.
    /// Each icon takes 1.09 times its size along the edge. The space the
    /// Dock needs is 17.3 points plus 1.167 times the icon size. The results
    /// were within 3 points of what macOS reported or the screen showed.
    public struct Fit: Equatable, Sendable {
        /// The icon size from the Dock's settings, in points.
        public var tileSize: Double
        /// How many icons the Dock holds, counting a separator as half.
        public var slots: Double
        /// What the Dock leaves free at the ends of the edge, in points.
        public var margin: Double

        public init(tileSize: Double, slots: Double, margin: Double = 74) {
            self.tileSize = tileSize
            self.slots = slots
            self.margin = margin
        }

        /// The space the Dock needs on an edge `edge` points long. Rounded
        /// up, since an overlap is worse than a thin gap.
        public func thickness(along edge: Int) -> Int {
            var tile = tileSize
            if slots > 0 { tile = min(tile, (Double(edge) - margin) / slots / 1.09) }
            return Int((17.3 + 1.167 * max(1, tile)).rounded(.up))
        }
    }

    /// The edge of a monitor the Dock sits along.
    public enum Edge: String, Equatable, Sendable {
        case bottom, left, right
    }

    /// - Parameters:
    ///   - frames: every monitor's full rectangle.
    ///   - usable: the area macOS reports as free on each monitor.
    ///   - dock: the rectangle of the Dock's own window, which covers the
    ///     whole of the monitor the Dock is on. `nil` if it is not known.
    /// - Returns: `usable`, with the Dock's strip also taken off the monitor
    ///   the Dock is on when it was reported on another one. A hidden Dock
    ///   takes no space and changes nothing.
    public static func corrected(frames: [Rect], usable: [Rect], dock: Rect?, fit: Fit? = nil,
                                 hidden: Bool = false, edge: Edge? = nil) -> [Rect] {
        analysed(frames: frames, usable: usable, dock: dock, fit: fit, hidden: hidden, edge: edge).usable
    }

    /// As `corrected` plus `spare`: for each monitor, the height of an
    /// empty strip below its usable area that the Dock has left behind.
    ///
    /// With `fit`, the strip taken off the monitor the Dock is on has the
    /// thickness the Dock is estimated to have there. Without it, the
    /// thickness reported for the other monitor is used as it is.
    ///
    /// `hidden` says the Dock is set to hide itself. It then takes no space
    /// on the monitor it is on. A strip macOS still reports for it, which
    /// happens once the Dock has moved, is given as `spare`.
    ///
    /// `edge` is the edge the Dock is set to in its settings. The report can
    /// be out of date about that too: after the Dock was moved to the left,
    /// macOS went on reporting a strip along the bottom of another monitor.
    /// Without it, the edge of the reported strip is assumed.
    public static func analysed(frames: [Rect], usable: [Rect], dock: Rect?, fit: Fit? = nil,
                                hidden: Bool = false, edge: Edge? = nil) -> (usable: [Rect], spare: [Int]) {
        let none = Array(repeating: 0, count: usable.count)
        guard frames.count == usable.count else { return (usable, none) }
        // The menu bar is at the top, so space missing on any other side is the Dock's.
        func strip(_ i: Int) -> (edge: Edge, thickness: Int)? {
            let bottom = frames[i].bottom - usable[i].bottom
            let left = usable[i].x - frames[i].x
            let right = frames[i].right - usable[i].right
            if bottom > 0 { return (.bottom, bottom) }
            if left > 0 { return (.left, left) }
            if right > 0 { return (.right, right) }
            return nil
        }
        guard let reported = frames.indices.first(where: { strip($0) != nil }), let found = strip(reported) else {
            return (usable, none)
        }
        var spare = none
        if found.edge == .bottom { spare[reported] = found.thickness }
        if hidden { return (usable, spare) }
        guard let dock = dock, let actual = frames.firstIndex(of: dock) else { return (usable, none) }
        let wanted = edge ?? found.edge
        // The Dock runs along the width at the bottom and along the height,
        // under the menu bar, at a side.
        func length(_ i: Int, _ e: Edge) -> Int { e == .bottom ? frames[i].width : usable[i].height }
        let thickness = fit?.thickness(along: length(actual, wanted)) ?? found.thickness
        var result = usable
        if actual == reported, wanted == found.edge {
            // Reported where the Dock is. The figure can still be too small:
            // after the Dock was made bigger, macOS went on reporting its old
            // thickness and the windows ran underneath it. It can also stay
            // too large after the Dock was made smaller. Terminal goes by the
            // reported figure, so the part the Dock no longer covers is
            // spare: windows may reach into it but not start in it.
            let extra = thickness - found.thickness
            guard extra > 0 else {
                var spare = none
                if fit != nil, wanted == .bottom { spare[actual] = -extra }
                return (usable, spare)
            }
            switch wanted {
            case .bottom: result[actual].height -= extra
            case .left: result[actual].x += extra; result[actual].width -= extra
            case .right: result[actual].width -= extra
            }
            return (result, none)
        }
        switch wanted {
        case .bottom:
            // On the monitor the strip was reported for, it is already taken off.
            if actual != reported || found.edge != .bottom { result[actual].height -= thickness }
        case .left:
            result[actual].x += thickness
            result[actual].width -= thickness
        case .right:
            result[actual].width -= thickness
        }
        return (result, spare)
    }
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
