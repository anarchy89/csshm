// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CsshmCore

struct ScriptError: Error, CustomStringConvertible {
    let number: Int
    let message: String

    var description: String {
        if number == -1743 {
            return "macOS did not allow csshm to control Terminal. Allow it in System Settings > Privacy & Security > Automation."
        }
        return "Terminal scripting failed (\(number)): \(message)"
    }
}

/// Drives Terminal.app with generated AppleScript, one script per batch of
/// work. Windows are always addressed by their id, never by position.
final class TerminalBackend: WindowBackend {
    /// When set, the primary display is reported as this many screens side
    /// by side, so multi-screen behaviour can be tried on a single display.
    private let pretendScreens: Int?
    /// The csshm program to run for a fresh reading of the monitors.
    private let probe: String?
    /// Height of the primary display at the last reading.
    private var primaryHeight: Int?

    /// `probe` is for a process that stays running, like the master. Such a
    /// process goes on seeing the monitors as they were when it started: a
    /// Dock that has since been resized, moved or hidden and a menu bar that
    /// has since been hidden do not show up, however long it waits. A new
    /// process sees them, so each reading is taken by running csshm again
    /// with `--probe_screens`.
    init(pretendScreens: Int? = nil, probe: String? = nil) {
        self.pretendScreens = pretendScreens
        self.probe = probe
    }

    @discardableResult
    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw ScriptError(number: 0, message: "could not create script")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            throw ScriptError(
                number: error[NSAppleScript.errorNumber] as? Int ?? 0,
                message: error[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
        return result
    }

    private func quoted(_ text: String) -> String {
        var out = "\""
        for ch in text {
            if ch == "\\" || ch == "\"" { out.append("\\") }
            out.append(ch)
        }
        return out + "\""
    }

    private func list(_ color: RGB) -> String {
        "{\(color.red), \(color.green), \(color.blue)}"
    }

    /// The AppleScript that moves and sizes a window.
    ///
    /// It sets `frame`, not `bounds`. With more than one monitor, Terminal
    /// reads the heights in `set bounds` relative to the monitor the window
    /// is on at that moment, so a window sent to another monitor lands too
    /// high or too low. `frame` is measured from the bottom-left of the
    /// primary display wherever the window is. Reading `bounds` is correct.
    private func place(_ window: String, at r: Rect) -> String {
        let primaryHeight = self.primaryHeight ?? Int((NSScreen.screens.first?.frame.height ?? 0).rounded())
        let e = r.bottomLeftEdges(primaryHeight: primaryHeight)
        return "set frame of window id \(window) to {\(e[0]), \(e[1]), \(e[2]), \(e[3])}"
    }

    func screens() throws -> [Rect] {
        try measureScreens().usable
    }

    func spareBelowScreens() throws -> [Int] {
        if let count = pretendScreens, count > 1 { return Array(repeating: 0, count: count) }
        return try measureScreens().spare
    }

    private func measureScreens() throws -> (usable: [Rect], spare: [Int]) {
        let reading = probe.flatMap { runProbe($0) } ?? measureHere()
        if reading.primaryHeight > 0 { primaryHeight = reading.primaryHeight }
        if let count = pretendScreens, count > 1, let first = reading.usable.first {
            return (first.splitIntoColumns(count), [])
        }
        return (reading.usable, reading.spare)
    }

    private typealias Reading = (primaryHeight: Int, usable: [Rect], spare: [Int])

    /// Prints a reading for `runProbe` in another csshm to pick up: the
    /// primary display's height, then one line per monitor.
    static func printProbe() {
        let reading = TerminalBackend().measureHere()
        print("primary \(reading.primaryHeight)")
        for (rect, spare) in zip(reading.usable, reading.spare) {
            print("\(rect.x) \(rect.y) \(rect.width) \(rect.height) \(spare)")
        }
    }

    private func runProbe(_ program: String) -> Reading? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = ["--probe_screens"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var height = 0
        var usable: [Rect] = []
        var spare: [Int] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.count == 2, words[0] == "primary", let h = Int(words[1]) {
                height = h
            } else if words.count == 5, let v = Optional(words.compactMap { Int($0) }), v.count == 5 {
                usable.append(Rect(x: v[0], y: v[1], width: v[2], height: v[3]))
                spare.append(v[4])
            }
        }
        return usable.isEmpty ? nil : (height, usable, spare)
    }

    private func measureHere() -> Reading {
        // Without a connection to the window system, macOS leaves the menu
        // bar out of visibleFrame on some monitors (seen on external ones
        // that are not the primary display). Windows sent there were pushed
        // down by Terminal and overlapped the row below. Creating the shared
        // application makes that connection and the frames come out right.
        // It shows nothing: no Dock icon and no menu.
        _ = NSApplication.shared
        let all = NSScreen.screens
        guard let primary = all.first else { return (0, [], []) }
        func rect(_ frame: NSRect) -> Rect {
            Rect(bottomLeftX: frame.minX, bottomLeftY: frame.minY, width: frame.width, height: frame.height,
                 primaryHeight: primary.frame.height)
        }
        let measured = DockSpace.analysed(frames: all.map { rect($0.frame) },
                                          usable: all.map { rect($0.visibleFrame) },
                                          dock: dockWindow(), fit: dockFit(), hidden: dockHides(), edge: dockEdge())
        return (Int(primary.frame.height.rounded()), measured.usable, measured.spare)
    }

    /// The rectangle of the Dock's window, which covers the monitor the Dock
    /// is on. It needs no permission: only the owner, level and position of
    /// the window are read, not its contents or title.
    private func dockWindow() -> Rect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        for window in list where window[kCGWindowOwnerName as String] as? String == "Dock"
            && window[kCGWindowLayer as String] as? Int == dockLevel {
            guard let b = window[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
            return Rect(x: Int(x.rounded()), y: Int(y.rounded()), width: Int(w.rounded(.down)), height: Int(h.rounded(.down)))
        }
        return nil
    }

    /// The edge the Dock is set to, from its settings. The bottom when unset.
    private func dockEdge() -> DockSpace.Edge {
        let name = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        return DockSpace.Edge(rawValue: name) ?? .bottom
    }

    /// Whether the Dock is set to hide itself, from its settings.
    private func dockHides() -> Bool {
        UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// The Dock's icon size and how many icons it holds, from its settings.
    /// The count leaves out apps that are running but not kept in the Dock.
    /// Too low a count makes the estimate thicker, which errs on the safe side.
    private func dockFit() -> DockSpace.Fit? {
        guard let dock = UserDefaults(suiteName: "com.apple.dock") else { return nil }
        let tile = dock.object(forKey: "tilesize") as? Double ?? 48
        let apps = dock.array(forKey: "persistent-apps")?.count ?? 0
        let others = dock.array(forKey: "persistent-others")?.count ?? 0
        let showRecents = dock.object(forKey: "show-recents") as? Bool ?? true
        let recents = showRecents ? min(3, dock.array(forKey: "recent-apps")?.count ?? 0) : 0
        // Finder and the Bin are always there. So are the separators between the groups.
        let slots = Double(apps + others + recents + 2) + (recents > 0 ? 1 : 0.5)
        return DockSpace.Fit(tileSize: tile, slots: slots)
    }

    func openWindows(_ requests: [WindowRequest]) throws -> [Int?] {
        guard !requests.isEmpty else { return [] }
        var lines = ["set out to \"\"", "tell application \"Terminal\""]
        for request in requests {
            lines.append("set t to do script \(quoted(request.command))")
            lines.append("set w to 0")
            // The new window is found through the tab that was just created,
            // never by its position on screen.
            lines.append("try")
            lines.append("set w to id of (first window whose tabs contains t)")
            lines.append("end try")
            // Profile and font come first: both make Terminal resize the window.
            if let profile = request.profile {
                lines.append("try")
                lines.append("set current settings of t to settings set \(quoted(profile))")
                lines.append("end try")
            }
            if let size = request.fontSize {
                lines.append("try")
                lines.append("set font size of t to \(size)")
                lines.append("end try")
            }
            if let r = request.bounds {
                lines.append("try")
                lines.append("if w is not 0 then " + place("w", at: r))
                lines.append("end try")
            }
            lines.append("set out to out & w & \",\"")
        }
        lines.append("end tell")
        lines.append("return out")
        let text = try run(lines.joined(separator: "\n")).stringValue ?? ""
        var ids = text.split(separator: ",", omittingEmptySubsequences: false).dropLast().map { field -> Int? in
            guard let id = Int(field), id != 0 else { return nil }
            return id
        }
        while ids.count < requests.count { ids.append(nil) }
        return Array(ids.prefix(requests.count))
    }

    func listWindows() throws -> [WindowInfo] {
        // Ask for each property of all windows at once: four requests in
        // total, however many windows there are. The lists only line up if
        // every window has a tab, so fall back to asking window by window
        // when they do not (a settings window or a sheet is open).
        let bulk = """
        set AppleScript's text item delimiters to "|"
        tell application "Terminal"
            set ids to id of every window
            set ttys to tty of tab 1 of every window
            set backs to background color of tab 1 of every window
            set fores to normal text color of tab 1 of every window
            set sizes to font size of tab 1 of every window
        end tell
        if (count of ids) is not (count of ttys) then error "windows without tabs"
        set out to ""
        repeat with i from 1 to count of ids
            set out to out & (item i of ids) & "|" & (item i of ttys) & "|" & ((item i of backs) as text) & "|" & ((item i of fores) as text) & "|" & (item i of sizes) & linefeed
        end repeat
        return out
        """
        let oneByOne = """
        set out to ""
        set AppleScript's text item delimiters to "|"
        tell application "Terminal"
            repeat with w in windows
                try
                    set t to tab 1 of w
                    set out to out & ((id of w) as text) & "|" & (tty of t) & "|" & ((background color of t) as text) & "|" & ((normal text color of t) as text) & "|" & ((font size of t) as text) & linefeed
                end try
            end repeat
        end tell
        return out
        """
        let text: String
        if let fast = try? run(bulk).stringValue {
            text = fast
        } else {
            text = try run(oneByOne).stringValue ?? ""
        }
        var windows: [WindowInfo] = []
        for line in text.split(separator: "\n") {
            // id | tty | three background channels | three text channels | font size
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 9, let id = Int(fields[0]) else { continue }
            let channels = fields[2..<8].compactMap { UInt16($0.filter { !$0.isWhitespace }) }
            guard channels.count == 6 else { continue }
            windows.append(WindowInfo(
                id: id,
                tty: String(fields[1]),
                background: RGB(channels[0], channels[1], channels[2]),
                foreground: RGB(channels[3], channels[4], channels[5]),
                fontSize: Int(Double(fields[8].filter { !$0.isWhitespace }) ?? 0)))
        }
        return windows
    }

    func profileNames() throws -> [String] {
        let result = try run("tell application \"Terminal\" to get name of every settings set")
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    func bounds(of window: Int) throws -> Rect {
        let result = try run("tell application \"Terminal\" to get bounds of window id \(window)")
        guard result.numberOfItems == 4 else {
            throw ScriptError(number: 0, message: "unexpected bounds for window \(window)")
        }
        let v = (1...4).map { Int(result.atIndex($0)?.int32Value ?? 0) }
        return Rect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
    }

    func perform(_ ops: [WindowOp]) throws {
        guard !ops.isEmpty else { return }
        var lines = ["tell application \"Terminal\""]
        // Each change is guarded on its own: a window the user has closed
        // must not stop the rest of the batch.
        func guarded(_ statement: String) {
            lines.append("try")
            lines.append(statement)
            lines.append("end try")
        }
        /// "window id 5" or for several windows one specifier that covers
        /// them all, so Terminal changes them in a single request.
        func target(_ ids: [Int]) -> String {
            ids.count == 1
                ? "window id \(ids[0])"
                : "(every window whose " + ids.map { "id is \($0)" }.joined(separator: " or ") + ")"
        }
        var index = 0
        while index < ops.count {
            switch ops[index] {
            case .setFontSize:
                // A run of font changes: one statement per distinct size.
                var groups: [(size: Int, ids: [Int])] = []
                while index < ops.count, case .setFontSize(let id, let size) = ops[index] {
                    if let g = groups.firstIndex(where: { $0.size == size }) { groups[g].ids.append(id) } else { groups.append((size, [id])) }
                    index += 1
                }
                for group in groups {
                    guarded("set font size of tab 1 of \(target(group.ids)) to \(group.size)")
                }
                continue
            case .setColors:
                // A run of colour changes: one pair of statements per distinct colouring.
                var groups: [(foreground: RGB, background: RGB, ids: [Int])] = []
                while index < ops.count, case .setColors(let id, let foreground, let background) = ops[index] {
                    if let g = groups.firstIndex(where: { $0.foreground == foreground && $0.background == background }) {
                        groups[g].ids.append(id)
                    } else {
                        groups.append((foreground, background, [id]))
                    }
                    index += 1
                }
                for group in groups {
                    guarded("set background color of tab 1 of \(target(group.ids)) to \(list(group.background))")
                    guarded("set normal text color of tab 1 of \(target(group.ids)) to \(list(group.foreground))")
                }
                continue
            case .show:
                // A run of windows to un-minimise and un-hide, in one request each.
                var ids: [Int] = []
                while index < ops.count, case .show(let id) = ops[index] { ids.append(id); index += 1 }
                guarded("set miniaturized of \(target(ids)) to false")
                guarded("set visible of \(target(ids)) to true")
                continue
            case .hide:
                var ids: [Int] = []
                while index < ops.count, case .hide(let id) = ops[index] { ids.append(id); index += 1 }
                guarded("set visible of \(target(ids)) to false")
                continue
            case .minimise:
                var ids: [Int] = []
                while index < ops.count, case .minimise(let id) = ops[index] { ids.append(id); index += 1 }
                guarded("set miniaturized of \(target(ids)) to true")
                continue
            case .setBounds(let id, let r):
                guarded(place(String(id), at: r))
            case .raise:
                // A run of windows to bring forward together. Their order
                // among themselves does not matter: they do not overlap.
                var ids: [Int] = []
                while index < ops.count, case .raise(let id) = ops[index] { ids.append(id); index += 1 }
                guarded("set frontmost of \(target(ids)) to true")
                continue
            case .close(let id):
                guarded("close window id \(id) saving no")
            case .setProfile(let id, let name):
                guarded("set current settings of tab 1 of window id \(id) to settings set \(quoted(name))")
            }
            index += 1
        }
        lines.append("end tell")
        try run(lines.joined(separator: "\n"))
    }

    func history(of window: Int) throws -> String {
        try run("tell application \"Terminal\" to get history of tab 1 of window id \(window)").stringValue ?? ""
    }

    func activate() throws {
        try run("tell application \"Terminal\" to activate")
    }

    /// The command line for a helper that closes a window shortly after the
    /// calling process has gone, so the window has no live process left.
    static func delayedCloseCommand(window: Int) -> [String] {
        ["/usr/bin/osascript",
         "-e", "delay 0.4",
         "-e", "tell application \"Terminal\" to close window id \(window) saving no"]
    }
}
