// SPDX-License-Identifier: GPL-3.0-or-later

/// How the grid is shaped. Columns are worked out from the number of windows
/// on every layout unless the user pinned them.
public struct GridOptions: Equatable, Sendable {
    /// Fixed column count per screen (`--tile_x`); 0 means automatic.
    public var tileX: Int
    /// Fixed row count per screen (`--tile_y`); 0 means automatic. Ignored
    /// when `tileX` is set.
    public var tileY: Int
    /// Adjustment to the automatic column count, from the grid keys.
    public var columnOffset: Int
    /// Height reserved for the master window at the bottom of the first screen.
    public var masterHeight: Int

    public init(tileX: Int = 0, tileY: Int = 0, columnOffset: Int = 0, masterHeight: Int = 87) {
        self.tileX = tileX
        self.tileY = tileY
        self.columnOffset = columnOffset
        self.masterHeight = masterHeight
    }
}

public struct GridLayout: Equatable, Sendable {
    /// Where the master window goes: the bottom strip of the first screen.
    public var master: Rect
    /// One rectangle per host window, in the order the windows were given.
    public var windows: [Rect]
    /// For each window, the area of its screen that host windows may use
    /// (what a zoomed window fills).
    public var areas: [Rect]
    /// Number of host windows on each screen.
    public var counts: [Int]
    /// Columns used on each screen (0 for a screen with no windows).
    public var columns: [Int]
    /// What the column count on each screen would be with no adjustment.
    public var automaticColumns: [Int]

    /// The automatic column count for `count` windows. Of the three counts
    /// nearest the square root, it takes the one that leaves the fewest empty
    /// cells. On a tie it prefers more columns for a landscape area, where
    /// that keeps windows a usable shape and fewer for a portrait one.
    public static func automaticColumns(for count: Int, landscape: Bool = true) -> Int {
        guard count > 1 else { return 1 }
        var base = 1
        while base * base < count { base += 1 }
        let candidates = [base - 1, base, base + 1].filter { $0 >= 1 && $0 <= count }
        func empty(_ columns: Int) -> Int { (columns - count % columns) % columns }
        return candidates.min { a, b in
            if empty(a) != empty(b) { return empty(a) < empty(b) }
            return landscape ? a > b : a < b
        }!
    }

    /// The column count for one screen holding `count` windows.
    public static func columns(for count: Int, options: GridOptions, landscape: Bool = true) -> Int {
        guard count > 0 else { return 0 }
        let wanted: Int
        if options.tileX > 0 {
            wanted = options.tileX
        } else if options.tileY > 0 {
            wanted = (count + options.tileY - 1) / options.tileY
        } else {
            wanted = automaticColumns(for: count, landscape: landscape) + options.columnOffset
        }
        return min(max(wanted, 1), count)
    }

    /// Shares `count` windows between screens in proportion to usable area,
    /// so windows come out a similar size on every screen.
    public static func distribute(count: Int, areas: [Rect]) -> [Int] {
        guard !areas.isEmpty else { return [] }
        guard count > 0 else { return Array(repeating: 0, count: areas.count) }
        let weights = areas.map { Double($0.area) }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            return [count] + Array(repeating: 0, count: areas.count - 1)
        }
        let quotas = weights.map { Double(count) * $0 / total }
        var shares = quotas.map { Int($0.rounded(.down)) }
        var left = count - shares.reduce(0, +)
        // Hand out what rounding left over, largest remainder first.
        let order = quotas.indices.sorted {
            let a = quotas[$0] - quotas[$0].rounded(.down)
            let b = quotas[$1] - quotas[$1].rounded(.down)
            return a == b ? $0 < $1 : a > b
        }
        var next = 0
        while left > 0 {
            shares[order[next % order.count]] += 1
            next += 1
            left -= 1
        }
        return shares
    }

    /// Lays out `count` host windows over `screens` (visible frames, in the
    /// order the user asked for them), one independent grid per screen.
    public static func compute(count: Int, screens: [Rect], options: GridOptions) -> GridLayout {
        precondition(!screens.isEmpty, "at least one screen is required")
        let first = screens[0]
        let masterHeight = min(max(options.masterHeight, 0), first.height)
        let master = Rect(x: first.x, y: first.bottom - masterHeight, width: first.width, height: masterHeight)

        var usable = screens
        usable[0].height -= masterHeight

        let counts = distribute(count: count, areas: usable)
        var windows: [Rect] = []
        var areas: [Rect] = []
        var columnsUsed: [Int] = []
        var automatic: [Int] = []
        for (index, area) in usable.enumerated() {
            let n = counts[index]
            let landscape = area.width >= area.height
            let cols = columns(for: n, options: options, landscape: landscape)
            columnsUsed.append(cols)
            automatic.append(n > 0 ? automaticColumns(for: n, landscape: landscape) : 0)
            guard n > 0 else { continue }
            let rows = (n + cols - 1) / cols
            let cellWidth = area.width / cols
            let cellHeight = area.height / rows
            for k in 0..<n {
                windows.append(Rect(
                    x: area.x + (k % cols) * cellWidth,
                    y: area.y + (k / cols) * cellHeight,
                    width: cellWidth,
                    height: cellHeight))
                areas.append(area)
            }
        }
        return GridLayout(master: master, windows: windows, areas: areas, counts: counts,
                          columns: columnsUsed, automaticColumns: automatic)
    }

    /// Finds the window to move the selection to from `current`, going one
    /// step in the direction (`dx`, `dy`). It works on window positions, so it
    /// crosses between screens naturally. It stays in the same row or column
    /// where it can, wrapping at the far edge and otherwise takes the nearest
    /// window in that direction.
    public static func neighbor(of current: Int, dx: Int, dy: Int, in rects: [Rect]) -> Int? {
        guard rects.indices.contains(current), rects.count > 1, (dx != 0) != (dy != 0) else { return nil }
        let from = rects[current]
        func along(_ r: Rect) -> Double {
            (r.centerX - from.centerX) * Double(dx) + (r.centerY - from.centerY) * Double(dy)
        }
        func across(_ r: Rect) -> Double {
            abs((r.centerX - from.centerX) * Double(dy)) + abs((r.centerY - from.centerY) * Double(dx))
        }
        /// True when `r` shares part of the current window's row (for a
        /// horizontal move) or column (for a vertical one).
        func sameBand(_ r: Rect) -> Bool {
            dx != 0
                ? r.y < from.bottom && from.y < r.bottom
                : r.x < from.right && from.x < r.right
        }
        let others = rects.indices.filter { $0 != current }
        let band = others.filter { sameBand(rects[$0]) }

        func nearest(_ candidates: [Int]) -> Int? {
            candidates.min { a, b in
                let ka = (along(rects[a]), across(rects[a]))
                let kb = (along(rects[b]), across(rects[b]))
                return ka == kb ? a < b : ka < kb
            }
        }
        if let next = nearest(band.filter { along(rects[$0]) > 0.5 }) { return next }
        // Nothing further that way in this row or column: wrap to its far end.
        if let wrapped = nearest(band.filter { along(rects[$0]) < -0.5 }) { return wrapped }
        // An empty row or column: take the closest window in that direction.
        return others.filter { along(rects[$0]) > 0.5 }.min { a, b in
            let ka = along(rects[a]) + 4 * across(rects[a])
            let kb = along(rects[b]) + 4 * across(rects[b])
            return ka == kb ? a < b : ka < kb
        }
    }
}
