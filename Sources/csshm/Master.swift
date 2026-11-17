// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

/// Set by the window-resize signal; the main loop redraws when it sees it.
private var windowResized: sig_atomic_t = 0

/// One host and its window, as the master tracks it.
final class HostWindow {
    let id: Int
    let spec: HostSpec
    var fd: Int32 = -1
    var decoder = MessageDecoder()
    /// Bytes waiting to be written to this host's process.
    var outgoing: [UInt8] = []
    var tty: String?
    var windowID: Int?
    var original: (foreground: RGB, background: RGB)?
    var fontSize = 0
    var shown: (foreground: RGB?, background: RGB?) = (nil, nil)
    /// The user switched input off for this host.
    var disabled = false
    /// The session ended with an error and the window is showing it.
    var dead = false
    var rect: Rect?
    var area: Rect?
    var zoomed = false
    let created = Date()

    init(id: Int, spec: HostSpec) {
        self.id = id
        self.spec = spec
    }

    var name: String { spec.original }
    var connected: Bool { fd >= 0 }
    var receivesInput: Bool { connected && !disabled && !dead }
}

/// The red window. It reads the keyboard, sends what is typed to every
/// enabled host, runs the Ctrl-A menu, and keeps the windows tiled.
final class Master {
    private let session: String
    private let config: SessionConfig
    private let backend: WindowBackend
    private let debug: Bool

    private var machine: ControlMachine
    private let colors: SessionColors
    private let menuKeyName: String
    private var hosts: [Int: HostWindow] = [:]
    private var nextID = 1
    private var sortKind = ControlMachine.SortKind.id
    /// Connections that have not yet said which host they are.
    private var strangers: [Int32: MessageDecoder] = [:]
    private var listenFD: Int32 = -1

    private var masterWindow: Int?
    private var screens: [Int]
    private var grid: GridOptions
    private var measuredOn: Rect?
    private var lastLayout: GridLayout?
    private var adjustedForCount = -1
    private var selection: Int?

    private var status = ""
    private var needsRedraw = true
    private var lastInput = Date()
    private var resolveAt: Date?
    private var retileAt: Date?
    private var retileFirstAsked: Date?
    private var closeQueue: [Int] = []
    private var quitDeadline: Date?
    private var savedTerminal = termios()
    private var terminalSaved = false

    init(session: String) {
        self.session = session
        guard let data = FileManager.default.contents(atPath: session + "/config.json"),
              let config = try? JSONDecoder().decode(SessionConfig.self, from: data) else {
            die("cannot read the session in \(session)")
        }
        self.config = config
        self.backend = TerminalBackend(pretendScreens: config.pretendScreens)
        self.debug = config.debug > 0
        self.machine = ControlMachine(actionKey: config.menuKey ?? 0x01)
        self.colors = config.colors
        self.menuKeyName = MenuKey.name(config.menuKey ?? 0x01)
        self.screens = config.screens
        self.grid = GridOptions(tileX: config.tileX, tileY: config.tileY, masterHeight: config.masterHeight)
        for spec in config.hosts {
            hosts[nextID] = HostWindow(id: nextID, spec: spec)
            nextID += 1
        }
    }

    // MARK: - Main loop

    func run() -> Never {
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGWINCH) { _ in windowResized = 1 }

        guard let fd = listenUnix(at: session + "/sock") else {
            die("cannot create the session socket in \(session)")
        }
        listenFD = fd
        enterRawMode()

        locateOwnWindow()
        if let window = masterWindow {
            var ops: [WindowOp] = []
            if let profile = config.masterProfile { ops.append(.setProfile(window: window, name: profile)) }
            ops.append(.setColors(window: window, foreground: colors.masterText, background: colors.masterBackground))
            apply(ops)
        }
        status = "Opening \(hosts.count) window\(hosts.count == 1 ? "" : "s")..."
        writeAll(1, "\u{1b}[H\u{1b}[2J\u{1b}[3J")  // drop the launch command from the window
        draw()
        open(ordered)
        status = ""

        while true {
            if windowResized != 0 {
                windowResized = 0
                needsRedraw = true
            }
            if needsRedraw { draw() }

            var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
            let strangerFDs = Array(strangers.keys)
            for fd in strangerFDs {
                fds.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0))
            }
            let connected = hosts.values.filter { $0.connected }
            for host in connected {
                let events = POLLIN | (host.outgoing.isEmpty ? 0 : POLLOUT)
                fds.append(pollfd(fd: host.fd, events: Int16(events), revents: 0))
            }

            let ready = poll(&fds, nfds_t(fds.count), timeoutMilliseconds())
            if ready < 0 && errno != EINTR { break }
            if ready > 0 {
                if fds[0].revents != 0 { readKeyboard() }
                if Int32(fds[1].revents) & POLLIN != 0 { acceptConnections() }
                var index = 2
                for fd in strangerFDs {
                    if fds[index].revents != 0 { readStranger(fd) }
                    index += 1
                }
                for host in connected {
                    let events = Int32(fds[index].revents)
                    index += 1
                    if events & POLLOUT != 0, host.connected { flush(host) }
                    if events & (POLLIN | POLLHUP | POLLERR) != 0, host.connected { readHost(host) }
                }
            }
            runTimers()

            if hosts.isEmpty { break }
            if let deadline = quitDeadline, deadline <= Date() { break }
        }
        shutdown(closeWindows: true)
    }

    private func timeoutMilliseconds() -> Int32 {
        var deadlines: [Date] = []
        if machine.hasPending { deadlines.append(lastInput.addingTimeInterval(0.03)) }
        if let t = resolveAt { deadlines.append(t) }
        if let t = retileAt { deadlines.append(t) }
        if let t = quitDeadline { deadlines.append(t) }
        if hosts.values.contains(where: { !$0.connected }) { deadlines.append(Date().addingTimeInterval(1)) }
        guard let soonest = deadlines.min() else { return -1 }
        return Int32(max(0, (soonest.timeIntervalSinceNow * 1000).rounded(.up)))
    }

    private func runTimers() {
        let now = Date()
        if machine.hasPending, now.timeIntervalSince(lastInput) >= 0.03 {
            perform(machine.flush())
        }
        if let t = resolveAt, t <= now {
            resolveAt = nil
            resolveWindows()
        }
        if let t = retileAt, t <= now {
            retileAt = nil
            retileFirstAsked = nil
            closeQueuedWindows()
            retile(raise: false)
        }
        for host in hosts.values where !host.connected && now.timeIntervalSince(host.created) > 30 {
            status = "\(host.name): the window did not start"
            hosts.removeValue(forKey: host.id)
            needsRedraw = true
        }
    }

    // MARK: - Keyboard

    private func enterRawMode() {
        guard tcgetattr(0, &savedTerminal) == 0 else { return }
        terminalSaved = true
        var raw = savedTerminal
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
    }

    private func readKeyboard() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(0, &buffer, buffer.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        if n <= 0 {
            // The master window was closed. The host windows carry on alone.
            shutdown(closeWindows: false)
        }
        lastInput = Date()
        perform(machine.feed(Array(buffer[0..<n])))
    }

    private func perform(_ actions: [ControlMachine.Action]) {
        for action in actions {
            switch action {
            case .send(let bytes):
                for host in hosts.values where host.receivesInput {
                    send(.input(bytes), to: host)
                }
            case .modeChanged(let mode):
                if mode == .action { status = "" }
                if mode == .enable {
                    unzoomAll()
                    selection = ordered.first { $0.rect != nil }?.id
                } else {
                    selection = nil
                }
                refreshColors()
                needsRedraw = true
            case .lineChanged:
                needsRedraw = true
            case .retile:
                retile(raise: true)
            case .gridMore:
                adjustColumns(by: 1)
            case .gridLess:
                adjustColumns(by: -1)
            case .fontSmaller:
                adjustFont(by: -1)
            case .fontLarger:
                adjustFont(by: 1)
            case .addHost(let text):
                addHost(text)
            case .selectMove(let dx, let dy):
                moveSelection(dx: dx, dy: dy)
            case .enableSelected:
                selected?.disabled = false
                refreshColors()
            case .disableSelected:
                selected?.disabled = true
                refreshColors()
            case .toggleSelected:
                selected?.disabled.toggle()
                refreshColors()
            case .onlySelected(let zoom):
                guard let target = selected else { break }
                for host in hosts.values { host.disabled = host !== target }
                refreshColors()
                if zoom { self.zoom(target) }
            case .enableAll:
                unzoomAll()
                for host in hosts.values { host.disabled = false }
                refreshColors()
            case .toggleAll:
                unzoomAll()
                for host in hosts.values { host.disabled.toggle() }
                refreshColors()
            case .enableNext:
                enableNext()
            case .minimise:
                apply(windowIDs.map { .minimise(window: $0) })
            case .hide:
                apply(windowIDs.map { .hide(window: $0) })
            case .tidy:
                apply(windowIDs.map { .hide(window: $0) } + (masterWindow.map { [.minimise(window: $0)] } ?? []))
            case .sendText(let kind):
                sendText(kind)
            case .sort(let kind):
                sortKind = kind
                retile(raise: false)
            case .dumpScrollback(let name):
                dumpScrollback(to: name)
            case .moveToScreen(let text):
                moveToScreen(text)
            case .quit:
                beginQuit()
            case .beep:
                writeAll(1, "\u{07}")
            }
            needsRedraw = true
        }
    }

    // MARK: - Connections

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            setNonBlocking(fd)
            setCloseOnExec(fd)
            strangers[fd] = MessageDecoder()
        }
    }

    private func readStranger(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard n > 0, var decoder = strangers[fd] else {
            strangers.removeValue(forKey: fd)
            close(fd)
            return
        }
        decoder.feed(buffer[0..<n])
        let message: Message?
        do {
            message = try decoder.next()
        } catch {
            message = .quit  // anything that is not a greeting is rejected below
        }
        guard let first = message else {
            strangers[fd] = decoder
            return
        }
        strangers.removeValue(forKey: fd)
        guard case .hello(let id, let tty, _) = first, let host = hosts[Int(id)], !host.connected else {
            close(fd)
            return
        }
        host.fd = fd
        host.decoder = decoder
        host.tty = tty
        log("hello from \(host.name) on \(tty)")
        let argv = host.spec.command(ssh: config.ssh, sshArgs: config.sshArgs, login: config.login, remoteCommand: config.remoteCommand)
        send(.run(argv: argv, title: "csshm - \(host.name)", debug: debug), to: host)
        if resolveAt == nil { resolveAt = Date().addingTimeInterval(0.15) }
        needsRedraw = true
    }

    private func send(_ message: Message, to host: HostWindow) {
        guard host.connected else { return }
        host.outgoing += message.encoded()
        flush(host)
    }

    private func flush(_ host: HostWindow) {
        while !host.outgoing.isEmpty {
            let n = host.outgoing.withUnsafeBytes { write(host.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                host.outgoing.removeFirst(n)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return  // the rest goes out when the socket has room
            } else {
                hostLeft(host)
                return
            }
        }
    }

    private func readHost(_ host: HostWindow) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(host.fd, &buffer, buffer.count)
        if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard n > 0 else {
            hostLeft(host)
            return
        }
        host.decoder.feed(buffer[0..<n])
        do {
            while let message = try host.decoder.next() {
                if case .exited = message {
                    host.dead = true
                    status = "\(host.name) ended with an error"
                    refreshColors()
                    needsRedraw = true
                }
            }
        } catch {
            hostLeft(host)
        }
    }

    /// A host's process has exited: forget it, close its window and re-tile.
    private func hostLeft(_ host: HostWindow) {
        guard hosts[host.id] === host else { return }
        log("\(host.name) left")
        if host.windowID == nil, host.tty != nil { resolveWindows() }
        close(host.fd)
        host.fd = -1
        hosts.removeValue(forKey: host.id)
        if let window = host.windowID { closeQueue.append(window) }
        if selection == host.id {
            selection = machine.mode == .enable ? ordered.first { $0.rect != nil }?.id : nil
            refreshColors()
        }
        askRetile(after: 0.4)
        needsRedraw = true
    }

    // MARK: - Windows

    private var ordered: [HostWindow] {
        switch sortKind {
        case .id:
            return hosts.values.sorted { $0.id < $1.id }
        case .host:
            return hosts.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        }
    }

    private var windowIDs: [Int] { ordered.compactMap { $0.windowID } }
    private var selected: HostWindow? { selection.flatMap { hosts[$0] } }

    private func apply(_ ops: [WindowOp]) {
        guard !ops.isEmpty else { return }
        do {
            try backend.perform(ops)
        } catch {
            log("window operations failed: \(error)")
            status = "\(error)"
            needsRedraw = true
        }
    }

    private func locateOwnWindow() {
        guard masterWindow == nil, let tty = controllingTTY(), let windows = try? backend.listWindows() else { return }
        masterWindow = windows.filter { $0.tty == tty }.map { $0.id }.max()
        log("master window \(masterWindow.map(String.init) ?? "not found") on \(tty)")
    }

    private func open(_ newHosts: [HostWindow]) {
        let commands = newHosts.map {
            SessionConfig.roleCommand(executable: config.executable, role: "slave", session: session, slaveID: $0.id)
        }
        do {
            try backend.openWindows(commands: commands)
            log("opened \(commands.count) window(s)")
        } catch {
            log("opening windows failed: \(error)")
            status = "\(error)"
        }
        // New windows take the keyboard; give it back to the master.
        if let window = masterWindow { apply([.raise(window: window)]) }
        needsRedraw = true
    }

    /// Matches each connected host to its Terminal window by terminal device.
    /// A finished window can still report a device that has since been
    /// reused, so the newest window with that device is the live one.
    private func resolveWindows() {
        let waiting = hosts.values.filter { $0.windowID == nil && $0.tty != nil }
        guard !waiting.isEmpty || masterWindow == nil else { return }
        log("looking up \(waiting.count) window(s)")
        guard var windows = try? backend.listWindows() else { return }
        if masterWindow == nil { locateOwnWindow() }
        func newest(for host: HostWindow, in list: [WindowInfo]) -> WindowInfo? {
            list.filter { $0.tty == host.tty }.max(by: { $0.id < $1.id })
        }
        // A profile or font size has to be in place before the window's own
        // colours and size are noted, because both change them.
        if config.profile != nil || config.fontSize != nil {
            var styling: [WindowOp] = []
            for host in waiting {
                guard let match = newest(for: host, in: windows) else { continue }
                if let profile = config.profile { styling.append(.setProfile(window: match.id, name: profile)) }
                if let size = config.fontSize { styling.append(.setFontSize(window: match.id, size: size)) }
            }
            if !styling.isEmpty {
                apply(styling)
                windows = (try? backend.listWindows()) ?? windows
            }
        }
        var found = false
        for host in waiting {
            guard let match = newest(for: host, in: windows) else { continue }
            host.windowID = match.id
            host.original = (match.foreground, match.background)
            host.fontSize = match.fontSize
            found = true
            log("\(host.name) is window \(match.id)")
        }
        if found {
            refreshColors()
            askRetile(after: 0.4)
        }
        if hosts.values.contains(where: { $0.windowID == nil && $0.connected && Date().timeIntervalSince($0.created) < 20 }) {
            resolveAt = Date().addingTimeInterval(0.5)
        }
    }

    /// Asks for a re-tile once things have been quiet for `delay`, so that
    /// forty windows closing together cause one re-tile, not forty.
    private func askRetile(after delay: TimeInterval) {
        let now = Date()
        if retileFirstAsked == nil { retileFirstAsked = now }
        retileAt = min(retileFirstAsked!.addingTimeInterval(2), now.addingTimeInterval(delay))
    }

    private func closeQueuedWindows() {
        guard !closeQueue.isEmpty else { return }
        if !debug { apply(closeQueue.map { .close(window: $0) }) }
        closeQueue = []
    }

    private func chosenScreens() -> [Rect]? {
        let all: [Rect]
        do {
            all = try backend.screens()
        } catch {
            status = "\(error)"
            return nil
        }
        guard !all.isEmpty else { return nil }
        let chosen = screens.compactMap { (1...all.count).contains($0) ? all[$0 - 1] : nil }
        return chosen.isEmpty ? [all[0]] : chosen
    }

    /// Lays every window out afresh from the current number of windows.
    /// With `raise`, also un-hides the windows and brings them to the front.
    private func retile(raise: Bool) {
        guard let chosen = chosenScreens() else { return }
        let placed = ordered.filter { $0.windowID != nil }

        // Terminal enforces a minimum window height. Find out how tall the
        // master really is on this screen and give the hosts what is left.
        if let window = masterWindow, measuredOn != chosen[0] {
            let first = chosen[0]
            let planned = Rect(x: first.x, y: first.bottom - config.masterHeight, width: first.width, height: config.masterHeight)
            apply([.show(window: window), .setBounds(window: window, planned)])
            if let actual = try? backend.bounds(of: window) {
                grid.masterHeight = max(config.masterHeight, actual.height)
            }
            measuredOn = first
        }

        // A column adjustment made with the grid keys belongs to the windows
        // that were there at the time; once that number changes, work the
        // columns out afresh.
        if placed.count != adjustedForCount { grid.columnOffset = 0 }
        let layout = GridLayout.compute(count: placed.count, screens: chosen, options: grid)
        lastLayout = layout
        var ops: [WindowOp] = []
        for (index, host) in placed.enumerated() {
            let window = host.windowID!
            if raise { ops.append(.show(window: window)) }
            ops.append(.setBounds(window: window, layout.windows[index]))
            if raise { ops.append(.raise(window: window)) }
            host.rect = layout.windows[index]
            host.area = layout.areas[index]
            host.zoomed = false
        }
        if let window = masterWindow {
            if raise { ops.append(.show(window: window)) }
            ops.append(.setBounds(window: window, layout.master))
            if raise { ops.append(.raise(window: window)) }
        }
        log("retile: \(placed.count) windows, columns \(layout.columns), screens \(chosen)")
        apply(ops)
        log("retile done")
    }

    private func refreshColors() {
        var ops: [WindowOp] = []
        for host in hosts.values {
            guard let window = host.windowID, let original = host.original else { continue }
            let want = colors.hostColors(inactive: host.disabled || host.dead, selected: selection == host.id)
            if want.foreground != host.shown.foreground || want.background != host.shown.background {
                ops.append(.setColors(
                    window: window,
                    foreground: want.foreground ?? original.foreground,
                    background: want.background ?? original.background))
                host.shown = want
            }
        }
        apply(ops)
    }

    private func zoom(_ host: HostWindow) {
        guard let window = host.windowID, let area = host.area else { return }
        var ops: [WindowOp] = [.setBounds(window: window, area), .raise(window: window)]
        if let master = masterWindow { ops.append(.raise(window: master)) }
        apply(ops)
        host.zoomed = true
    }

    private func unzoomAll() {
        var ops: [WindowOp] = []
        for host in hosts.values where host.zoomed {
            if let window = host.windowID, let rect = host.rect {
                ops.append(.setBounds(window: window, rect))
            }
            host.zoomed = false
        }
        apply(ops)
    }

    // MARK: - Menu actions

    private func moveSelection(dx: Int, dy: Int) {
        let placed = ordered.filter { $0.rect != nil }
        guard !placed.isEmpty else { return }
        guard let current = placed.firstIndex(where: { $0.id == selection }) else {
            selection = placed[0].id
            refreshColors()
            return
        }
        if let next = GridLayout.neighbor(of: current, dx: dx, dy: dy, in: placed.map { $0.rect! }) {
            selection = placed[next].id
            refreshColors()
        }
    }

    private func adjustColumns(by delta: Int) {
        // Work from the screen holding the most windows.
        guard let layout = lastLayout, let busiest = layout.counts.indices.max(by: { layout.counts[$0] < layout.counts[$1] }),
              layout.counts[busiest] > 0 else { return }
        let wanted = min(max(layout.columns[busiest] + delta, 1), layout.counts[busiest])
        if grid.tileX > 0 || grid.tileY > 0 {
            grid.tileX = wanted
        } else {
            grid.columnOffset = wanted - layout.automaticColumns[busiest]
            adjustedForCount = hosts.values.filter { $0.windowID != nil }.count
        }
        retile(raise: false)
    }

    /// Changes the text size in every host window. Terminal resizes a
    /// window when its font changes, so the grid is put back afterwards.
    private func adjustFont(by delta: Int) {
        var ops: [WindowOp] = []
        for host in hosts.values {
            guard let window = host.windowID, host.fontSize > 0 else { continue }
            let size = min(max(host.fontSize + delta, 4), 72)
            guard size != host.fontSize else { continue }
            host.fontSize = size
            ops.append(.setFontSize(window: window, size: size))
        }
        guard !ops.isEmpty else {
            writeAll(1, "\u{07}")
            return
        }
        apply(ops)
        retile(raise: false)
        if let size = ordered.first(where: { $0.fontSize > 0 })?.fontSize {
            status = "Font size \(size)"
        }
    }

    private func addHost(_ text: String) {
        let spec: HostSpec
        do {
            spec = try HostSpec(parsing: text)
        } catch {
            status = "\(error)"
            writeAll(1, "\u{07}")
            return
        }
        let host = HostWindow(id: nextID, spec: spec)
        nextID += 1
        hosts[host.id] = host
        open([host])
    }

    /// With exactly one host enabled, moves on to the next one. With none
    /// enabled (the one that was has exited), starts again at the first.
    private func enableNext() {
        let live = ordered.filter { $0.connected && !$0.dead }
        let enabled = live.filter { !$0.disabled }
        if enabled.isEmpty, let first = live.first {
            first.disabled = false
            refreshColors()
            status = "Now typing to \(first.name)"
            return
        }
        guard live.count > 1, enabled.count == 1, let index = live.firstIndex(where: { $0 === enabled[0] }) else {
            writeAll(1, "\u{07}")
            return
        }
        let current = enabled[0]
        let next = live[(index + 1) % live.count]
        let wasZoomed = current.zoomed
        unzoomAll()
        current.disabled = true
        next.disabled = false
        refreshColors()
        if wasZoomed { zoom(next) }
        status = "Now typing to \(next.name)"
    }

    private func sendText(_ kind: ControlMachine.TextKind) {
        for host in ordered where host.receivesInput {
            let text: String
            switch kind {
            case .hostname: text = host.spec.host
            case .connection: text = host.spec.original
            case .windowID: text = host.windowID.map(String.init) ?? ""
            case .slaveID: text = String(host.id)
            }
            send(.input(Array(text.utf8)), to: host)
        }
    }

    private func dumpScrollback(to name: String) {
        let chosen = name.isEmpty ? "Desktop/csshm_scrollback" : name
        let base: String
        if chosen.hasPrefix("/") {
            base = chosen
        } else if chosen.hasPrefix("~") {
            base = (chosen as NSString).expandingTildeInPath
        } else {
            base = (NSHomeDirectory() as NSString).appendingPathComponent(chosen)
        }
        var used = Set<String>()
        var written = 0
        var failure: String?
        for host in ordered {
            guard let window = host.windowID else { continue }
            var label = String(host.name.map { ch -> Character in
                ch.isLetter || ch.isNumber || "-@.+()=_".contains(ch) ? ch : "_"
            })
            if used.contains(label) {
                var n = 1
                while used.contains("\(label).\(n)") { n += 1 }
                label = "\(label).\(n)"
            }
            used.insert(label)
            do {
                let text = try backend.history(of: window)
                try text.write(toFile: "\(base).\(label).txt", atomically: true, encoding: .utf8)
                written += 1
            } catch {
                failure = "\(error.localizedDescription)"
            }
        }
        status = "Saved \(written) file\(written == 1 ? "" : "s") as \(base).<host>.txt"
        if let failure = failure { status += " (some failed: \(failure))" }
    }

    private func moveToScreen(_ text: String) {
        do {
            let spec = try ScreenSpec(parsing: text)
            try spec.validate(available: try backend.screens().count)
            screens = spec.screens
            measuredOn = nil
            retile(raise: true)
            status = "Now on screen \(spec)"
        } catch {
            status = "\(error)"
            writeAll(1, "\u{07}")
        }
    }

    // MARK: - Leaving

    /// Asks every host process to end its session, so the windows can be
    /// closed without Terminal asking about running processes.
    private func beginQuit() {
        guard quitDeadline == nil else { return }
        quitDeadline = Date().addingTimeInterval(2.5)
        status = "Closing..."
        for host in hosts.values {
            if host.connected {
                send(.quit, to: host)
            } else {
                hosts.removeValue(forKey: host.id)
            }
        }
    }

    private func shutdown(closeWindows: Bool) -> Never {
        if closeWindows && !debug {
            usleep(250_000)  // let the last processes finish exiting
            apply((closeQueue + windowIDs).map { .close(window: $0) })
        }
        if terminalSaved { tcsetattr(0, TCSANOW, &savedTerminal) }
        writeAll(1, "\u{1b}[H\u{1b}[2J")
        close(listenFD)
        if !debug { try? FileManager.default.removeItem(atPath: session) }
        log("master exiting")
        if closeWindows && !debug, let window = masterWindow {
            // Our own window can only close cleanly once this process is gone.
            _ = spawn(TerminalBackend.delayedCloseCommand(window: window), detached: true)
        }
        exit(0)
    }

    // MARK: - Display

    private func draw() {
        needsRedraw = false
        var text = promptText()
        if !status.isEmpty { text += "\n" + status }
        let names = ordered.map { $0.name }.joined(separator: ", ")
        let title = "csshm - Master - " + (names.count > 120 ? String(names.prefix(117)) + "..." : names)
        // Redraw over the old text line by line. Clearing the whole screen
        // would make Terminal copy the old prompt into the scrollback each time.
        let body = text.replacingOccurrences(of: "\n", with: "\u{1b}[K\r\n")
        writeAll(1, "\u{1b}[H" + body + "\u{1b}[K\u{1b}[J\u{1b}]0;\(title)\u{07}")
    }

    private func promptText() -> String {
        switch machine.mode {
        case .input:
            let total = hosts.count
            let typing = hosts.values.filter { $0.receivesInput }.count
            let waiting = hosts.values.filter { !$0.connected }.count
            let dead = hosts.values.filter { $0.dead }.count
            var text = "Typing here goes to \(typing) of \(total) host\(total == 1 ? "" : "s"). \(menuKeyName) opens the menu."
            if waiting > 0 { text += "\nWaiting for \(waiting) window\(waiting == 1 ? "" : "s") to start." }
            if dead > 0 {
                text += "\n\(dead) ended with an error: press Enter in such a window to close it, or \(menuKeyName) x to close everything."
            }
            return text
        case .action:
            return """
            Menu (Esc: back, \(menuKeyName): send \(menuKeyName) to the hosts)
            [r]etile  [c] add host  [e]nable/disable  e[n]able all  [t]oggle all  [Space] next host
            [g/G] columns  [f/F] font  s[o]rt  [m]inimise  [h]ide  [s]end text  mo[v]e to screen  [d]ump scrollback  e[x]it
            """
        case .enable:
            let name = selected.map { "  Selected: \($0.name)\($0.disabled ? " (disabled)" : "")" } ?? ""
            return """
            Select a window with the arrow keys or h/j/k/l (Esc: back)\(name)
            [e]nable  [d]isable  [t]oggle  [o]nly this one  [O]nly this one, zoomed
            """
        case .sendText:
            return "Send to every enabled host (Esc: back)\n[h]ostname  [c]onnection string  window [i]d  [s]lave id"
        case .sort:
            return "Sort the windows by (Esc: back)\n[h]ostname  [i]d"
        case .addHost:
            return "Add host (Enter: connect, Esc: cancel): " + machine.line
        case .dumpScrollback:
            return "Save scrollback under your home folder as [Desktop/csshm_scrollback]: " + machine.line
        case .moveScreen:
            return "Move to screen(s), for example 2, 2-4 or 1,3 (Esc: cancel): " + machine.line
        }
    }

    private func log(_ message: String) {
        guard let path = config.logFile else { return }
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + message + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
