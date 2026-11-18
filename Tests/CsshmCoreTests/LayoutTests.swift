// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CsshmCore

final class ScreenSpecTests: XCTestCase {
    func testSingleRangeAndList() throws {
        XCTAssertEqual(try ScreenSpec(parsing: "3").screens, [3])
        XCTAssertEqual(try ScreenSpec(parsing: "3-4").screens, [3, 4])
        XCTAssertEqual(try ScreenSpec(parsing: "2-4").screens, [2, 3, 4])
        XCTAssertEqual(try ScreenSpec(parsing: "1,3").screens, [1, 3])
        XCTAssertEqual(try ScreenSpec(parsing: "4-2").screens, [4, 3, 2])
        XCTAssertEqual(try ScreenSpec(parsing: "1,2-3,2").screens, [1, 2, 3])
    }

    func testDefaultIsPrimary() throws {
        XCTAssertEqual(try ScreenSpec(parsing: "").screens, [1])
        XCTAssertEqual(try ScreenSpec(parsing: "0").screens, [1])
    }

    func testRejectsNonsense() {
        for bad in ["a", "1-", "-2", "1-2-3", "1,,2", "0-2", "1.5", "+2"] {
            XCTAssertThrowsError(try ScreenSpec(parsing: bad), bad)
        }
    }

    func testValidate() throws {
        XCTAssertNoThrow(try ScreenSpec(parsing: "1-3").validate(available: 3))
        XCTAssertThrowsError(try ScreenSpec(parsing: "2-4").validate(available: 3)) { error in
            XCTAssertEqual(error as? ScreenSpecError, .noSuchScreen(4, available: 3))
        }
    }
}

final class ScreenGeometryTests: XCTestCase {
    /// AppKit reports screens from the bottom-left of the primary display.
    /// These are the arrangements a desk with several monitors produces.
    func testConversionFromAppKitCoordinates() {
        let primaryHeight = 1080.0
        // The primary display itself, minus a 25-point menu bar and a 70-point Dock.
        XCTAssertEqual(
            Rect(bottomLeftX: 0, bottomLeftY: 70, width: 1920, height: 985, primaryHeight: primaryHeight),
            Rect(x: 0, y: 25, width: 1920, height: 985))
        // A monitor to the right, same height.
        XCTAssertEqual(
            Rect(bottomLeftX: 1920, bottomLeftY: 0, width: 1920, height: 1055, primaryHeight: primaryHeight),
            Rect(x: 1920, y: 25, width: 1920, height: 1055))
        // A monitor to the left has negative x.
        XCTAssertEqual(
            Rect(bottomLeftX: -2560, bottomLeftY: 0, width: 2560, height: 1440, primaryHeight: primaryHeight),
            Rect(x: -2560, y: -360, width: 2560, height: 1440))
        // A monitor above the primary has negative y.
        XCTAssertEqual(
            Rect(bottomLeftX: 0, bottomLeftY: 1080, width: 1920, height: 1080, primaryHeight: primaryHeight),
            Rect(x: 0, y: -1080, width: 1920, height: 1080))
        // A monitor below the primary starts past its bottom edge.
        XCTAssertEqual(
            Rect(bottomLeftX: 0, bottomLeftY: -1080, width: 1920, height: 1080, primaryHeight: primaryHeight),
            Rect(x: 0, y: 1080, width: 1920, height: 1080))
    }

    func testSplitIntoColumns() {
        let screen = Rect(x: 0, y: 30, width: 1710, height: 938)
        XCTAssertEqual(screen.splitIntoColumns(1), [screen])
        XCTAssertEqual(screen.splitIntoColumns(3), [
            Rect(x: 0, y: 30, width: 570, height: 938),
            Rect(x: 570, y: 30, width: 570, height: 938),
            Rect(x: 1140, y: 30, width: 570, height: 938),
        ])
    }
}

final class GridLayoutTests: XCTestCase {
    /// Four monitors around a desk: one left of the primary, one right, one
    /// above, with different sizes. Every window must sit wholly on one
    /// monitor and the master on the first monitor asked for.
    func testMixedMonitorsWithNegativeCoordinates() {
        let left = Rect(x: -2560, y: -360, width: 2560, height: 1440)
        let primary = Rect(x: 0, y: 25, width: 1920, height: 985)
        let right = Rect(x: 1920, y: 25, width: 1920, height: 1055)
        let above = Rect(x: 0, y: -1080, width: 1920, height: 1080)
        let screens = [above, left, right, primary]
        let layout = GridLayout.compute(count: 40, screens: screens, options: GridOptions(masterHeight: 124))
        XCTAssertEqual(layout.counts.reduce(0, +), 40)
        XCTAssertEqual(layout.master, Rect(x: 0, y: -124, width: 1920, height: 124), "bottom strip of the first screen given")
        // The biggest monitor gets the most windows.
        XCTAssertEqual(layout.counts.max(), layout.counts[1])
        for (index, window) in layout.windows.enumerated() {
            let homes = screens.filter { $0.x <= window.x && window.right <= $0.right && $0.y <= window.y && window.bottom <= $0.bottom }
            XCTAssertEqual(homes.count, 1, "window \(index) \(window)")
            let overlapsMaster = window.x < layout.master.right && layout.master.x < window.right
                && window.y < layout.master.bottom && layout.master.y < window.bottom
            XCTAssertFalse(overlapsMaster, "window \(index) overlaps the master")
        }
    }

    /// `--screen 2-4` used to mean screens 2 and 4 only.
    func testRangeUsesEveryScreenInIt() throws {
        let all = (0..<4).map { Rect(x: $0 * 1000, y: 0, width: 1000, height: 800) }
        let spec = try ScreenSpec(parsing: "2-4")
        let chosen = spec.screens.map { all[$0 - 1] }
        let layout = GridLayout.compute(count: 9, screens: chosen, options: GridOptions(masterHeight: 87))
        XCTAssertEqual(layout.counts.count, 3)
        XCTAssertFalse(layout.counts.contains(0))
        XCTAssertTrue(layout.windows.allSatisfy { $0.x >= 1000 }, "nothing on screen 1")
        XCTAssertTrue(layout.windows.contains { $0.x >= 2000 && $0.right <= 3000 }, "screen 3 is used")
    }

    let screen = Rect(x: 0, y: 25, width: 1800, height: 1087)

    func testAutomaticColumns() {
        let expected = [1: 1, 2: 2, 3: 3, 4: 2, 5: 3, 6: 3, 7: 4, 8: 4, 9: 3, 10: 5, 11: 4, 12: 4,
                        16: 4, 30: 6, 36: 6, 40: 8]
        for (count, columns) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(GridLayout.automaticColumns(for: count), columns, "\(count) windows")
        }
    }

    /// On a portrait screen, ties go to fewer columns so windows stay wide.
    func testAutomaticColumnsOnAPortraitScreen() {
        XCTAssertEqual(GridLayout.automaticColumns(for: 3, landscape: false), 1)
        XCTAssertEqual(GridLayout.automaticColumns(for: 7, landscape: false), 2)
        XCTAssertEqual(GridLayout.automaticColumns(for: 8, landscape: false), 2)
        XCTAssertEqual(GridLayout.automaticColumns(for: 36, landscape: false), 6)
        let portrait = Rect(x: 0, y: 0, width: 1080, height: 1920)
        XCTAssertEqual(GridLayout.compute(count: 7, screens: [portrait], options: GridOptions()).columns, [2])
    }

    /// Counts that do not fill a grid leave the last row short; nothing is
    /// stretched, dropped or overlapped.
    func testUnevenCounts() {
        let area = Rect(x: 0, y: 0, width: 1200, height: 800)
        let five = GridLayout.compute(count: 5, screens: [area], options: GridOptions(masterHeight: 0))
        XCTAssertEqual(five.columns, [3])
        XCTAssertEqual(five.windows.map { [$0.x, $0.y] }, [[0, 0], [400, 0], [800, 0], [0, 400], [400, 400]])
        XCTAssertTrue(five.windows.allSatisfy { $0.width == 400 && $0.height == 400 })

        let seven = GridLayout.compute(count: 7, screens: [area], options: GridOptions(masterHeight: 0))
        XCTAssertEqual(seven.columns, [4])
        XCTAssertEqual(seven.windows.filter { $0.y == 0 }.count, 4)
        XCTAssertEqual(seven.windows.filter { $0.y == 400 }.count, 3)
        XCTAssertTrue(seven.windows.allSatisfy { $0.width == 300 && $0.height == 400 })

        for count in 1...45 {
            let layout = GridLayout.compute(count: count, screens: [area], options: GridOptions())
            XCTAssertEqual(layout.windows.count, count)
            XCTAssertEqual(Set(layout.windows.map { [$0.x, $0.y] }).count, count, "\(count) windows share a cell")
            XCTAssertTrue(layout.windows.allSatisfy { $0.right <= area.right && $0.bottom <= layout.master.y })
        }
    }

    /// The csshX bug: closing 36 windows down to 4 kept six columns.
    func testColumnsFollowTheWindowCount() {
        let options = GridOptions()
        let many = GridLayout.compute(count: 36, screens: [screen], options: options)
        XCTAssertEqual(many.columns, [6])
        let few = GridLayout.compute(count: 4, screens: [screen], options: options)
        XCTAssertEqual(few.columns, [2])
        XCTAssertEqual(few.windows.count, 4)
        XCTAssertEqual(few.windows[0], Rect(x: 0, y: 25, width: 900, height: 500))
        XCTAssertEqual(few.windows[3], Rect(x: 900, y: 525, width: 900, height: 500))
    }

    func testMasterSitsAtTheBottomOfTheFirstScreen() {
        let layout = GridLayout.compute(count: 4, screens: [screen], options: GridOptions(masterHeight: 87))
        XCTAssertEqual(layout.master, Rect(x: 0, y: 1025, width: 1800, height: 87))
        for window in layout.windows {
            XCTAssertLessThanOrEqual(window.bottom, layout.master.y)
        }
    }

    func testPinnedColumnsAndRows() {
        XCTAssertEqual(GridLayout.columns(for: 12, options: GridOptions(tileX: 3)), 3)
        XCTAssertEqual(GridLayout.columns(for: 12, options: GridOptions(tileY: 2)), 6)
        XCTAssertEqual(GridLayout.columns(for: 12, options: GridOptions(tileX: 5, tileY: 2)), 5)
        // Never more columns than windows, never fewer than one.
        XCTAssertEqual(GridLayout.columns(for: 2, options: GridOptions(tileX: 6)), 2)
        XCTAssertEqual(GridLayout.columns(for: 9, options: GridOptions(columnOffset: -10)), 1)
        XCTAssertEqual(GridLayout.columns(for: 9, options: GridOptions(columnOffset: 1)), 4)
    }

    func testNoWindows() {
        let layout = GridLayout.compute(count: 0, screens: [screen], options: GridOptions())
        XCTAssertTrue(layout.windows.isEmpty)
        XCTAssertEqual(layout.counts, [0])
    }

    /// Every monitor in the range gets its own grid; no window straddles two.
    func testOneGridPerScreen() {
        let screens = [
            Rect(x: 0, y: 25, width: 1920, height: 1055),
            Rect(x: 1920, y: 0, width: 1920, height: 1080),
            Rect(x: 3840, y: 0, width: 1920, height: 1080),
        ]
        let layout = GridLayout.compute(count: 30, screens: screens, options: GridOptions())
        XCTAssertEqual(layout.counts.reduce(0, +), 30)
        XCTAssertEqual(layout.windows.count, 30)
        XCTAssertFalse(layout.counts.contains(0))
        for (index, window) in layout.windows.enumerated() {
            let home = screens.filter { $0.x <= window.x && window.right <= $0.right && $0.y <= window.y && window.bottom <= $0.bottom }
            XCTAssertEqual(home.count, 1, "window \(index) \(window) is not inside exactly one screen")
        }
        // No two windows overlap.
        for a in layout.windows.indices {
            for b in layout.windows.indices where a < b {
                let wa = layout.windows[a], wb = layout.windows[b]
                let apart = wa.right <= wb.x || wb.right <= wa.x || wa.bottom <= wb.y || wb.bottom <= wa.y
                XCTAssertTrue(apart, "windows \(a) and \(b) overlap")
            }
        }
    }

    func testDistributeFollowsArea() {
        let big = Rect(x: 0, y: 0, width: 2000, height: 1000)
        let small = Rect(x: 2000, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(GridLayout.distribute(count: 30, areas: [big, small]), [20, 10])
        XCTAssertEqual(GridLayout.distribute(count: 1, areas: [big, small]), [1, 0])
        XCTAssertEqual(GridLayout.distribute(count: 5, areas: [big, big]), [3, 2])
        XCTAssertEqual(GridLayout.distribute(count: 0, areas: [big, small]), [0, 0])
    }

    func testNeighborWithinAGrid() {
        // 3 columns, 2 rows, last row has two windows.
        let layout = GridLayout.compute(count: 5, screens: [screen], options: GridOptions(tileX: 3))
        let r = layout.windows
        XCTAssertEqual(GridLayout.neighbor(of: 0, dx: 1, dy: 0, in: r), 1)
        XCTAssertEqual(GridLayout.neighbor(of: 1, dx: 1, dy: 0, in: r), 2)
        XCTAssertEqual(GridLayout.neighbor(of: 2, dx: 1, dy: 0, in: r), 0, "wraps along the row")
        XCTAssertEqual(GridLayout.neighbor(of: 0, dx: -1, dy: 0, in: r), 2, "wraps the other way")
        XCTAssertEqual(GridLayout.neighbor(of: 0, dx: 0, dy: 1, in: r), 3)
        XCTAssertEqual(GridLayout.neighbor(of: 3, dx: 0, dy: -1, in: r), 0)
        XCTAssertEqual(GridLayout.neighbor(of: 3, dx: 0, dy: 1, in: r), 0, "wraps down the column")
        XCTAssertEqual(GridLayout.neighbor(of: 4, dx: 1, dy: 0, in: r), 3)
        XCTAssertNotNil(GridLayout.neighbor(of: 2, dx: 0, dy: 1, in: r), "skips the empty cell below")
        XCTAssertNil(GridLayout.neighbor(of: 0, dx: 1, dy: 0, in: [r[0]]))
    }

    func testNeighborCrossesScreens() {
        let screens = [Rect(x: 0, y: 0, width: 1000, height: 1000), Rect(x: 1000, y: 0, width: 1000, height: 1000)]
        let layout = GridLayout.compute(count: 8, screens: screens, options: GridOptions(masterHeight: 0))
        XCTAssertEqual(layout.counts, [4, 4])
        // Window 1 is top-right on the first screen; window 4 is top-left on the second.
        XCTAssertEqual(GridLayout.neighbor(of: 1, dx: 1, dy: 0, in: layout.windows), 4)
        XCTAssertEqual(GridLayout.neighbor(of: 4, dx: -1, dy: 0, in: layout.windows), 1)
    }
}
