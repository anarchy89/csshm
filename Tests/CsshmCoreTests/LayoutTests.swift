// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CsshmCore

final class ScreenSpecTests: XCTestCase {
    func testScreenList() {
        // The owner's four monitors: main, one to the left, one to the right, one below.
        let frames = [Rect(x: 0, y: 0, width: 3440, height: 1440), Rect(x: -1728, y: 182, width: 1728, height: 1117),
                      Rect(x: 3440, y: -584, width: 1440, height: 2560), Rect(x: 1520, y: 1440, width: 1920, height: 1080)]
        let usable = [Rect(x: 0, y: 30, width: 3440, height: 1410), Rect(x: -1728, y: 215, width: 1728, height: 1084),
                      Rect(x: 3440, y: -554, width: 1440, height: 2530), Rect(x: 1520, y: 1470, width: 1920, height: 960)]
        XCTAssertEqual(frames.map { ScreenList.place(of: $0, main: frames[0]) }, ["main", "left of 1", "right of 1", "below 1"])
        XCTAssertEqual(ScreenList.place(of: Rect(x: 0, y: -1080, width: 1920, height: 1080), main: frames[0]), "above 1")
        let lines = ScreenList.table(frames: frames, usable: usable, names: ["DELL S3422DWG", "Built-in Retina Display"]).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "MONITOR  NAME                     SIZE       PLACE       FREE AREA, AS A --bounds VALUE")
        XCTAssertEqual(lines[2], "2        Built-in Retina Display  1728x1117  left of 1   2:0,33-1728,1117")
        XCTAssertEqual(lines[4], "4        -                        1920x1080  below 1     4:0,30-1920,990")
        // Every value in the table is one --bounds accepts for that monitor.
        for (index, line) in lines.dropFirst().enumerated() {
            let area = try? ScreenBounds(parsing: String(line.split(separator: " ").last!))
            XCTAssertNotNil(area, line)
            XCTAssertNoThrow(try area?.check(frame: frames[index], usable: usable[index]), line)
        }
    }

    func testScreenBounds() throws {
        let area = try ScreenBounds(parsing: " 2:100,30-1720,1400 ")
        XCTAssertEqual(area.screen, 2)
        XCTAssertEqual(area.description, "2:100,30-1720,1400")
        // Corners are measured from the monitor's own top-left corner.
        let frame = Rect(x: 1710, y: -200, width: 3440, height: 1440)
        let usable = Rect(x: 1710, y: -170, width: 3440, height: 1410)
        XCTAssertEqual(area.rect(in: frame), Rect(x: 1810, y: -170, width: 1620, height: 1370))
        XCTAssertNoThrow(try area.check(frame: frame, usable: usable))
        // Under the menu bar or past the edge is refused, saying what is free.
        XCTAssertThrowsError(try ScreenBounds(parsing: "2:0,0-1720,1400").check(frame: frame, usable: usable)) { error in
            XCTAssertTrue("\(error)".contains("monitor 2 is free from 0,30 to 3440,1440"), "\(error)")
        }
        XCTAssertThrowsError(try ScreenBounds(parsing: "2:0,30-3441,1400").check(frame: frame, usable: usable))
        for bad in ["", "2", "2:0,0", "0:0,0-500,500", "2:0,0-100,500", "2:500,500-0,0", "2:a,0-500,500", "2:0,0-500,500-9", "2:-5,0-500,500"] {
            XCTAssertThrowsError(try ScreenBounds(parsing: bad), bad)
        }
    }

    func testScreenBoundsAreTrimmedWhenTheSpaceShrinks() throws {
        let frame = Rect(x: 0, y: 0, width: 1710, height: 1107)
        let area = try ScreenBounds(parsing: "1:0,0-860,1107")
        // The menu bar and the Dock came back: the area gives way to them.
        XCTAssertEqual(area.limited(to: Rect(x: 0, y: 30, width: 1710, height: 1000), frame: frame),
                       Rect(x: 0, y: 30, width: 860, height: 1000))
        // Too little left to use.
        XCTAssertNil(try ScreenBounds(parsing: "1:0,900-860,1107").limited(to: Rect(x: 0, y: 30, width: 1710, height: 1000), frame: frame))
    }

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

    /// The master sits on the monitor asked for. Hosts on that monitor make
    /// room for it and hosts on other monitors keep their full height.
    func testMasterOnAChosenScreen() {
        let main = Rect(x: 0, y: 30, width: 3440, height: 1410)
        let side = Rect(x: 3440, y: -554, width: 1440, height: 2530)
        var options = GridOptions()
        options.masterHeight = 87

        // Hosts only on the side monitor, master on the main one.
        let apart = GridLayout.compute(count: 8, screens: [side], options: options, masterScreen: main)
        XCTAssertEqual(apart.master, Rect(x: 0, y: 1353, width: 3440, height: 87))
        XCTAssertEqual(apart.windows.map { $0.bottom }.max(), side.bottom - (side.height % 4))
        XCTAssertTrue(apart.windows.allSatisfy { $0.x >= side.x })

        // Hosts on both, master on the second one listed.
        let shared = GridLayout.compute(count: 8, screens: [main, side], options: options, masterScreen: side)
        XCTAssertEqual(shared.master, Rect(x: 3440, y: side.bottom - 87, width: 1440, height: 87))
        let onSide = shared.windows.filter { $0.x >= side.x }
        let onMain = shared.windows.filter { $0.x < side.x }
        XCTAssertFalse(onSide.isEmpty)
        XCTAssertTrue(onSide.allSatisfy { $0.bottom <= side.bottom - 87 })
        XCTAssertGreaterThan(onMain.map { $0.bottom }.max() ?? 0, main.bottom - 87)

        // Not given: the first monitor listed, as before.
        XCTAssertEqual(GridLayout.compute(count: 4, screens: [side, main], options: options).master.x, side.x)
    }

    /// The Dock's strip is also reserved on the monitor the Dock is really on.
    func testDockSpaceFollowsTheDock() {
        let main = Rect(x: 0, y: 0, width: 3440, height: 1440)
        let below = Rect(x: 1520, y: 1440, width: 1920, height: 1080)
        let mainFree = Rect(x: 0, y: 30, width: 3440, height: 1410)
        let belowShort = Rect(x: 1520, y: 1470, width: 1920, height: 958)
        let belowFree = Rect(x: 1520, y: 1470, width: 1920, height: 1050)
        let leftShort = Rect(x: -1692, y: 215, width: 1692, height: 1084)

        // Reported on the monitor below while the Dock is on the main one.
        XCTAssertEqual(DockSpace.corrected(frames: [main, below], usable: [mainFree, belowShort], dock: main),
                       [Rect(x: 0, y: 30, width: 3440, height: 1318), belowShort])
        // Reported where the Dock is: nothing to do.
        XCTAssertEqual(DockSpace.corrected(frames: [main, below], usable: [mainFree, belowShort], dock: below), [mainFree, belowShort])
        // A hidden Dock takes no space. An unknown Dock changes nothing.
        XCTAssertEqual(DockSpace.corrected(frames: [main, below], usable: [mainFree, belowFree], dock: main), [mainFree, belowFree])
        XCTAssertEqual(DockSpace.corrected(frames: [main, below], usable: [mainFree, belowShort], dock: nil), [mainFree, belowShort])
        // A Dock at the side moves in the same way.
        let left = Rect(x: -1728, y: 182, width: 1728, height: 1117)
        XCTAssertEqual(DockSpace.corrected(frames: [main, left], usable: [mainFree, leftShort], dock: main),
                       [Rect(x: 36, y: 30, width: 3404, height: 1410), leftShort])
        // The Dock was switched to the left edge and went to the monitor on
        // the left, while the report still shows a strip under the other one.
        let leftFree = Rect(x: -1728, y: 215, width: 1728, height: 1084)
        XCTAssertEqual(DockSpace.corrected(frames: [main, below, left], usable: [mainFree, belowShort, leftFree], dock: left, edge: .left),
                       [mainFree, belowShort, Rect(x: -1636, y: 215, width: 1636, height: 1084)])
        // The same, with the Dock staying on the monitor it was reported for.
        XCTAssertEqual(DockSpace.corrected(frames: [main, below], usable: [mainFree, belowShort], dock: below, edge: .right),
                       [mainFree, Rect(x: 1520, y: 1470, width: 1828, height: 958)])
    }

    /// A strip the Dock left behind is used by a grid of two or more rows,
    /// not by a single row and not on the master's screen.
    func testSpareStripBelowAScreen() {
        let below = Rect(x: 1520, y: 1470, width: 1920, height: 958)
        let main = Rect(x: 0, y: 30, width: 3440, height: 1410)
        var options = GridOptions()
        options.masterHeight = 87
        let two = GridLayout.compute(count: 4, screens: [below], options: options, masterScreen: main, spare: [92])
        XCTAssertEqual(two.windows.map { $0.bottom }.max(), 1470 + 1050)
        XCTAssertEqual(two.windows[0].height, 525)
        let one = GridLayout.compute(count: 2, screens: [below], options: options, masterScreen: main, spare: [92])
        XCTAssertEqual(one.windows.map { $0.bottom }.max(), below.bottom)
        let withMaster = GridLayout.compute(count: 4, screens: [below], options: options, masterScreen: below, spare: [92])
        XCTAssertEqual(withMaster.master.bottom, below.bottom)
        XCTAssertTrue(withMaster.windows.allSatisfy { $0.bottom <= below.bottom - 87 })
        // The strip is reported for the monitor the Dock left.
        let frames = [Rect(x: 0, y: 0, width: 3440, height: 1440), Rect(x: 1520, y: 1440, width: 1920, height: 1080)]
        XCTAssertEqual(DockSpace.analysed(frames: frames, usable: [main, below], dock: frames[0]).spare, [0, 92])
        XCTAssertEqual(DockSpace.analysed(frames: frames, usable: [main, below], dock: frames[1]).spare, [0, 0])
    }

    /// The Dock is thinner on a monitor too narrow for its icons at full size.
    func testDockThicknessOnAnotherMonitor() {
        // Measured: macOS reported 92 on a 3440 wide monitor, 85 on a 1728
        // wide one and 75 on a 1440 wide one, with 25 icons of size 64.
        let fit = DockSpace.Fit(tileSize: 64, slots: 26)
        XCTAssertEqual(fit.thickness(along: 3440), 92)
        XCTAssertEqual(fit.thickness(along: 1728), 86)
        XCTAssertEqual(fit.thickness(along: 1440), 74)
        // Smaller icons: the Dock's top was 49 points up at size 30 and
        // macOS reported 36 at size 16.
        XCTAssertEqual(DockSpace.Fit(tileSize: 30, slots: 26).thickness(along: 1728), 53)
        XCTAssertEqual(DockSpace.Fit(tileSize: 16, slots: 26).thickness(along: 1728), 36)

        let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
        let tall = Rect(x: 1920, y: 0, width: 1440, height: 2560)
        let result = DockSpace.analysed(frames: [wide, tall],
                                        usable: [Rect(x: 0, y: 30, width: 1920, height: 958), Rect(x: 1920, y: 30, width: 1440, height: 2530)],
                                        dock: tall, fit: fit)
        XCTAssertEqual(result.usable[1], Rect(x: 1920, y: 30, width: 1440, height: 2530 - 74))
        XCTAssertEqual(result.spare, [92, 0])

        // Reported on the right monitor but with the thickness of the Dock
        // before it was made bigger: the larger figure is used. A report
        // that is larger than the estimate is left as it is.
        let grown = DockSpace.analysed(frames: [wide, tall],
                                       usable: [Rect(x: 0, y: 30, width: 1920, height: 1014), Rect(x: 1920, y: 30, width: 1440, height: 2530)],
                                       dock: wide, fit: fit)
        XCTAssertEqual(grown.usable[0], Rect(x: 0, y: 30, width: 1920, height: 958))
        let shrunk = DockSpace.analysed(frames: [wide, tall],
                                        usable: [Rect(x: 0, y: 30, width: 1920, height: 958), Rect(x: 1920, y: 30, width: 1440, height: 2530)],
                                        dock: wide, fit: DockSpace.Fit(tileSize: 16, slots: 26))
        XCTAssertEqual(shrunk.usable[0], Rect(x: 0, y: 30, width: 1920, height: 958))
        // The part of that strip the smaller Dock no longer covers is spare.
        XCTAssertEqual(shrunk.spare, [92 - 36, 0])
        // The master covers a spare strip below its screen by being taller.
        var options = GridOptions()
        options.masterHeight = 87
        let covered = GridLayout.compute(count: 4, screens: [wide], options: options, masterScreen: wide, masterSpare: 56)
        XCTAssertEqual(covered.master, Rect(x: 0, y: 1080 - 87, width: 1920, height: 87 + 56))
        XCTAssertTrue(covered.windows.allSatisfy { $0.bottom <= 1080 - 87 })

        // Set to hide: no space is taken where the Dock is. A strip
        // still reported for it elsewhere is only spare.
        let hidden = DockSpace.analysed(frames: [wide, tall],
                                        usable: [Rect(x: 0, y: 30, width: 1920, height: 958), Rect(x: 1920, y: 30, width: 1440, height: 2530)],
                                        dock: tall, fit: fit, hidden: true)
        XCTAssertEqual(hidden.usable[1], Rect(x: 1920, y: 30, width: 1440, height: 2530))
        XCTAssertEqual(hidden.spare, [92, 0])
    }

    /// Edges for Terminal's `frame`: measured upwards from the bottom-left of
    /// the primary display, also for monitors above, below and left of it.
    func testBottomLeftEdges() {
        XCTAssertEqual(Rect(x: 100, y: 100, width: 800, height: 500).bottomLeftEdges(primaryHeight: 1440), [100, 840, 900, 1340])
        XCTAssertEqual(Rect(x: -1700, y: 300, width: 800, height: 500).bottomLeftEdges(primaryHeight: 1440), [-1700, 640, -900, 1140])
        XCTAssertEqual(Rect(x: 3500, y: -500, width: 800, height: 500).bottomLeftEdges(primaryHeight: 1440), [3500, 1440, 4300, 1940])
        XCTAssertEqual(Rect(x: 1600, y: 1500, width: 800, height: 500).bottomLeftEdges(primaryHeight: 1440), [1600, -560, 2400, -60])
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
