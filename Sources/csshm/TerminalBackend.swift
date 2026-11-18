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

    init(pretendScreens: Int? = nil) {
        self.pretendScreens = pretendScreens
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

    func screens() throws -> [Rect] {
        let all = NSScreen.screens
        guard let primary = all.first else { return [] }
        let real = all.map { screen -> Rect in
            let frame = screen.visibleFrame
            return Rect(bottomLeftX: frame.minX, bottomLeftY: frame.minY, width: frame.width, height: frame.height,
                        primaryHeight: primary.frame.height)
        }
        if let count = pretendScreens, count > 1 {
            return real[0].splitIntoColumns(count)
        }
        return real
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
                lines.append("if w is not 0 then set bounds of window id w to {\(r.x), \(r.y), \(r.right), \(r.bottom)}")
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
                guarded("set bounds of window id \(id) to {\(r.x), \(r.y), \(r.right), \(r.bottom)}")
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
