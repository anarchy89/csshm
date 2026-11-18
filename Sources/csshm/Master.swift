// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

/// Set by the window-resize signal; the main loop redraws when it sees it.
private var windowResized: sig_atomic_t = 0

/// Set by SIGUSR1, which asks for a re-tile the same as the menu's `r`.
/// It lets a script or a keyboard shortcut re-tile without typing in the
/// master window: kill -USR1 on the process running `csshm --master`.
private var retileSignalled: sig_atomic_t = 0

/// Set by SIGHUP, which Terminal sends when the master window is closed and
/// by SIGTERM. The main loop then tidies up and exits.
private var hangupSignalled: sig_atomic_t = 0

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
    /// The session ended and the window is being kept open to show its output.
    var dead = false
    /// The window's cell in the grid.
    var rect: Rect?
    var area: Rect?
    /// Where csshm last put the window; `nil` when that is no longer known.
    var placed: Rect?
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
/// enabled host, runs the Ctrl-A menu and keeps the windows tiled.
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
    /// The monitor the master window sits on, from `--master_screen`.
    private var masterHome: Rect?
    /// Set while the hosts are being laid out again around the master.
    private var fittingAroundMaster = false
    /// For each chosen monitor, the strip below it the grid may reach into.
    private var chosenSpare: [Int] = []
    /// The same for the master's monitor.
    private var masterSpare = 0
    private var masterPlaced: Rect?
    private var lastScreens: [Rect] = []
    /// Every monitor's usable area and spare strip at the last layout.
    private var lastReading: (all: [Rect], spare: [Int]) = ([], [])
    /// How many times a resized master has been looked at without the
    /// monitors having changed.
    private var masterChecks = 0
    private var lastLayout: GridLayout?
    private var adjustedForCount = -1
    private var selection: Int?

    private var status = ""
    private var needsRedraw = true
    private var lastInput = Date()
    private var resolveAt: Date?
    private var retileAt: Date?
    /// Whether the pending re-tile should move windows or only close the
    /// ones that have ended.
    private var retileWanted = false
    /// When to look at whether Terminal has resized the master window.
    private var masterCheckAt: Date?
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
        // --env values may be secrets and nothing reads this file again.
        if !config.environment.isEmpty { unlink(session + "/config.json") }
        self.backend = TerminalBackend(pretendScreens: config.pretendScreens, probe: config.executable)
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
        signal(SIGUSR1) { _ in retileSignalled = 1 }
        signal(SIGHUP) { _ in hangupSignalled = 1 }
        signal(SIGTERM) { _ in hangupSignalled = 1 }

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
            // The master window was closed. The host windows carry on alone.
            if hangupSignalled != 0 { shutdown(closeWindows: false) }
            if windowResized != 0 {
                windowResized = 0
                needsRedraw = true
                // The master's own window changed size. If csshm did not do
                // that, Terminal did: see checkMaster.
                if masterWindow != nil {
                    masterCheckAt = Date().addingTimeInterval(0.7)
                    masterChecks = 0
                }
            }
            if retileSignalled != 0 {
                retileSignalled = 0
                log("re-tile asked for by signal")
                closeQueuedWindows()
                retile(raise: true)
                status = "Re-tiled"
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

            // The master outlives its hosts: when the last one closes it
            // stays, so a host can be added again from the menu. It only
            // goes when the user quits.
            if quitDeadline != nil, hosts.isEmpty { break }
            if let deadline = quitDeadline, deadline <= Date() { break }
        }
        shutdown(closeWindows: true)
    }

    private func timeoutMilliseconds() -> Int32 {
        var deadlines: [Date] = []
        if machine.hasPending { deadlines.append(lastInput.addingTimeInterval(0.03)) }
        if let t = resolveAt { deadlines.append(t) }
        if let t = retileAt { deadlines.append(t) }
        if let t = masterCheckAt { deadlines.append(t) }
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
            if retileWanted { retile(raise: false) }
            retileWanted = false
        }
        if let t = masterCheckAt, t <= now {
            masterCheckAt = nil
            checkMaster()
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
            case .rerunEnded:
                rerunEnded()
            case .clearScrollback:
                let windows = hosts.values.filter { $0.connected }
                for host in windows { send(.clearScrollback, to: host) }
                status = "Cleared the scrollback of \(windows.count) window\(windows.count == 1 ? "" : "s")."
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
        let argv = config.commandTemplate?.command(for: host.spec, login: config.login)
            ?? host.spec.command(ssh: config.ssh, sshArgs: config.sshArgs, login: config.login, remoteCommand: config.remoteCommand)
        // ssh reports its own failures with status 255. Other programs have
        // no such convention, so for them a quick failure counts as one.
        send(.run(argv: argv, title: "csshm - \(host.name)", debug: debug, holdQuickFailure: config.commandTemplate != nil, keepOpen: config.keepOpen, environment: config.environment), to: host)
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
                if case .exited(let code) = message {
                    host.dead = true
                    status = code == 0 ? "\(host.name) finished" : "\(host.name) ended with an error"
                    refreshColors()
                    needsRedraw = true
                }
            }
        } catch {
            hostLeft(host)
        }
    }

    /// A host's process has exited: forget it and close its window. With
    /// `--retile auto` the remaining windows are then laid out again.
    /// Otherwise the gap stays until the user asks, so that no window moves
    /// while they are reading it or reaching for it.
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
        askRetile(after: 0.4, layout: config.autoRetile)
        if hosts.isEmpty {
            status = "\(host.name) closed. No hosts are left: \(menuKeyName) x closes this window."
        } else if !config.autoRetile {
            status = "\(host.name) closed. \(menuKeyName) r re-tiles."
        }
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
        let started = Date()
        defer { log(String(format: "%d window change(s) took %.0f ms", ops.count, Date().timeIntervalSince(started) * 1000)) }
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

    /// Opens windows for `newHosts`. The grid is worked out first, counting
    /// the new windows, so each one opens already in its cell.
    private func open(_ newHosts: [HostWindow]) {
        let future = ordered.filter { host in host.windowID != nil || newHosts.contains { $0 === host } }
        let layout = planLayout(count: future.count)
        var cells: [Int: (rect: Rect, area: Rect)] = [:]
        if let layout = layout {
            for (index, host) in future.enumerated() {
                cells[host.id] = (layout.windows[index], layout.areas[index])
            }
        }
        let requests = newHosts.map { host in
            WindowRequest(
                command: SessionConfig.roleCommand(executable: config.executable, role: "slave", session: session, slaveID: host.id),
                bounds: cells[host.id]?.rect,
                profile: config.profile,
                fontSize: config.fontSize)
        }
        do {
            let ids = try backend.openWindows(requests)
            for (host, id) in zip(newHosts, ids) {
                host.windowID = id
                if id != nil, let cell = cells[host.id] {
                    host.rect = cell.rect
                    host.area = cell.area
                    host.placed = cell.rect
                }
            }
            log("opened \(requests.count) window(s), \(ids.compactMap { $0 }.count) placed")
        } catch {
            log("opening windows failed: \(error)")
            status = "\(error)"
        }
        // New windows take the keyboard; give it back to the master.
        if let window = masterWindow { apply([.raise(window: window)]) }
        // Windows that were already open move to their new cells and the
        // master takes its final place. Windows already in place are skipped.
        retile(raise: false)
        needsRedraw = true
    }

    /// Reads each connected host's window: its own colours and font size,
    /// which csshm needs before it can change and later restore them. A
    /// window whose id is not known yet is found by its terminal device; a
    /// finished window can still report a device that has since been reused,
    /// so the newest window with that device is the live one.
    private func resolveWindows() {
        let waiting = hosts.values.filter { $0.original == nil && $0.tty != nil }
        guard !waiting.isEmpty || masterWindow == nil else { return }
        log("looking up \(waiting.count) window(s)")
        guard let windows = try? backend.listWindows() else { return }
        if masterWindow == nil { locateOwnWindow() }
        var discovered = false
        for host in waiting {
            let byDevice = windows.filter { $0.tty == host.tty }.max(by: { $0.id < $1.id })
            guard let match = windows.first(where: { $0.id == host.windowID && $0.tty == host.tty }) ?? byDevice else { continue }
            if host.windowID != match.id {
                log("\(host.name) is window \(match.id)")
                host.windowID = match.id
                host.placed = nil
                discovered = true
            }
            host.original = (match.foreground, match.background)
            host.fontSize = match.fontSize
        }
        refreshColors()
        if discovered { askRetile(after: 0.4) }
        if hosts.values.contains(where: { $0.original == nil && $0.connected && Date().timeIntervalSince($0.created) < 20 }) {
            resolveAt = Date().addingTimeInterval(0.5)
        }
    }

    /// Asks for a re-tile once things have been quiet for `delay`, so that
    /// forty windows closing together cause one re-tile, not forty.
    ///
    /// Without `layout`, only the queued windows are closed when the time
    /// comes and the others stay where they are.
    private func askRetile(after delay: TimeInterval, layout: Bool = true) {
        if layout { retileWanted = true }
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
        var all: [Rect]
        do {
            all = try backend.screens()
        } catch {
            status = "\(error)"
            return nil
        }
        guard !all.isEmpty else { return nil }
        let numbers = screens.filter { (1...all.count).contains($0) }
        // From the same reading as `all`, not a second one.
        var spare = (try? backend.spareBelowScreens()) ?? []
        lastReading = (all, spare)
        // --bounds: keep to the given part of a monitor. The master follows,
        // since its monitor is taken from the same list.
        if !config.bounds.isEmpty, let frames = try? backend.frames(), frames.count == all.count {
            for bounds in config.bounds where (1...all.count).contains(bounds.screen) {
                let index = bounds.screen - 1
                guard let limited = bounds.limited(to: all[index], frame: frames[index]) else { continue }
                // A strip the Dock left behind only matters to an area that reaches it.
                if limited.bottom != all[index].bottom, index < spare.count { spare[index] = 0 }
                all[index] = limited
            }
        }
        masterHome = (1...all.count).contains(config.masterScreen) ? all[config.masterScreen - 1] : all[0]
        masterSpare = (1...max(1, spare.count)).contains(config.masterScreen) && !spare.isEmpty ? spare[config.masterScreen - 1] : 0
        chosenSpare = (numbers.isEmpty ? [1] : numbers).map { $0 <= spare.count ? spare[$0 - 1] : 0 }
        let chosen = numbers.map { all[$0 - 1] }
        return chosen.isEmpty ? [all[0]] : chosen
    }

    /// Works out the grid for `count` host windows on the chosen screens.
    private func planLayout(count: Int) -> GridLayout? {
        guard let chosen = chosenScreens() else { return nil }
        lastScreens = chosen

        // Terminal enforces a minimum window height. Find out how tall the
        // master really is on this screen and give the hosts what is left.
        let home = masterHome ?? chosen[0]
        if let window = masterWindow, measuredOn != home {
            let first = home
            let planned = Rect(x: first.x, y: first.bottom - config.masterHeight, width: first.width, height: config.masterHeight)
            apply([.show(window: window), .setBounds(window: window, planned)])
            if let actual = try? backend.bounds(of: window) {
                grid.masterHeight = max(config.masterHeight, actual.height)
                log("master measured: asked for \(planned), got \(actual), reserving \(grid.masterHeight)")
            }
            measuredOn = first
            masterPlaced = nil
        }

        // A column adjustment made with the grid keys belongs to the windows
        // that were there at the time; once that number changes, work the
        // columns out afresh.
        if count != adjustedForCount { grid.columnOffset = 0 }
        let layout = GridLayout.compute(count: count, screens: chosen, options: grid, masterScreen: home, spare: chosenSpare, masterSpare: masterSpare)
        lastLayout = layout
        return layout
    }

    /// Puts every window in its cell, worked out from the current number of
    /// windows. A window csshm already put in the right place is left alone.
    /// With `raise`, every window is placed regardless, un-hidden and brought
    /// to the front: that is the user asking for everything to be put back.
    private func retile(raise: Bool) {
        let placed = ordered.filter { $0.windowID != nil }
        guard let layout = planLayout(count: placed.count) else { return }
        var ops: [WindowOp] = []
        var moved = 0
        // Un-hiding comes first and all together, so it can go to Terminal
        // as one request for every window.
        if raise {
            ops += placed.map { .show(window: $0.windowID!) }
            if let window = masterWindow { ops.append(.show(window: window)) }
        }
        for (index, host) in placed.enumerated() {
            let window = host.windowID!
            let cell = layout.windows[index]
            if raise || host.placed != cell {
                ops.append(.setBounds(window: window, cell))
                moved += 1
            }
            host.rect = cell
            host.area = layout.areas[index]
            host.placed = cell
            host.zoomed = false
        }
        // The host windows come forward together; the master follows on its
        // own so that it ends up in front with the keyboard.
        if raise { ops += placed.map { .raise(window: $0.windowID!) } }
        if let window = masterWindow {
            if raise || masterPlaced != layout.master {
                ops.append(.setBounds(window: window, layout.master))
                masterPlaced = layout.master
            }
            if raise { ops.append(.raise(window: window)) }
        }
        log("retile: \(placed.count) windows, \(moved) moved, columns \(layout.columns), screens \(lastScreens)")
        apply(ops)
        log("retile done")
        fitAroundMaster(planned: layout.master)
    }

    /// Puts things right after Terminal has resized the master by itself.
    ///
    /// When the menu bar or the Dock changes (seen when the menu bar was
    /// switched from hidden to shown), Terminal looks over its windows again
    /// and stretches the master to its own minimum of five rows, which then
    /// covers the bottom of the host windows. The space on the monitors has
    /// usually changed as well, so everything is laid out afresh.
    private func checkMaster() {
        guard !debug, let window = masterWindow, let placed = masterPlaced,
              let actual = try? backend.bounds(of: window) else { return }
        // Hidden with Ctrl-H or left as csshm placed it: nothing to do.
        guard abs(actual.height - placed.height) > 2 || abs(actual.y - placed.y) > 2 else { return }
        guard actual.x < placed.right, actual.right > placed.x else { return }
        // Terminal does this when the space on the monitors changes. If it
        // has not changed, the user resized the master, which is theirs to
        // decide: it stays as it is until they ask for a re-tile. macOS can
        // take a moment to report a change, so look once more before
        // settling on that.
        if let all = try? backend.screens(), let spare = try? backend.spareBelowScreens(),
           all == lastReading.all, spare == lastReading.spare {
            if masterChecks < 1 {
                masterChecks += 1
                masterCheckAt = Date().addingTimeInterval(1.5)
            } else {
                log("master is at \(actual), not \(placed), with the monitors unchanged: left as the user put it")
            }
            return
        }
        log("master is at \(actual), not \(placed): laying out again")
        masterPlaced = nil
        measuredOn = nil
        grid.masterHeight = config.masterHeight
        retile(raise: false)
    }

    /// Terminal has the last word on where the master window ends up. It
    /// moves the master up when its title bar would be inside a strip the
    /// Dock has left behind and it may refuse a height it finds too small.
    /// If the master reaches higher than planned, the host windows on its
    /// monitor are laid out again in the space above where it really is.
    private func fitAroundMaster(planned: Rect) {
        guard !fittingAroundMaster, !debug, let window = masterWindow, let home = masterHome,
              let actual = try? backend.bounds(of: window) else { return }
        let needed = home.bottom - actual.y
        let wanted = home.bottom - planned.y
        // A master on another monitor or far from the bottom was moved by
        // the user, which is theirs to decide.
        guard actual.x < home.right, actual.right > home.x, needed > wanted + 2, needed < home.height / 2 else { return }
        log("master reaches \(needed) up from the bottom, not \(wanted): fitting the hosts above it")
        grid.masterHeight = needed
        fittingAroundMaster = true
        retile(raise: false)
        fittingAroundMaster = false
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
        host.placed = area
    }

    private func unzoomAll() {
        var ops: [WindowOp] = []
        for host in hosts.values where host.zoomed {
            if let window = host.windowID, let rect = host.rect {
                ops.append(.setBounds(window: window, rect))
                host.placed = rect
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
            host.placed = nil  // Terminal resizes the window when its font changes
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
            try config.commandTemplate?.check(spec, login: config.login)
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

    /// Runs every host whose session has ended again: the ones kept open in
    /// grey after ssh failed or with `--remote_command_keepalive`. Each gets
    /// a new window in the same cell, since it keeps its number and with it
    /// its place in the order. The other hosts are not touched.
    private func rerunEnded() {
        let ended = ordered.filter { $0.dead }
        guard !ended.isEmpty else {
            status = "No host has ended, so there is nothing to run again."
            writeAll(1, "\u{07}")
            return
        }
        var fresh: [HostWindow] = []
        for old in ended {
            // The old process is only waiting for Enter and exits when told.
            send(.quit, to: old)
            if old.connected { close(old.fd) }
            old.fd = -1
            if let window = old.windowID { closeQueue.append(window) }
            let host = HostWindow(id: old.id, spec: old.spec)
            host.disabled = old.disabled
            hosts[host.id] = host
            fresh.append(host)
        }
        // Terminal only closes a window quietly once its process has gone.
        usleep(300_000)
        closeQueuedWindows()
        open(fresh)
        status = "Running \(fresh.count) host\(fresh.count == 1 ? "" : "s") again."
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
                // Scrollback can hold secrets: readable by the owner only.
                let path = "\(base).\(label).txt"
                try? FileManager.default.removeItem(atPath: path)
                guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
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
                text += "\n\(dead) \(config.keepOpen ? "finished" : "ended with an error"): \(menuKeyName) a runs \(dead == 1 ? "it" : "them") again, Enter in such a window closes it."
            }
            return text
        case .action:
            return """
            Menu (Esc: back, \(menuKeyName): send \(menuKeyName) to the hosts)
            [r]etile  [c] add host  run ended hosts [a]gain  [e]nable/disable  e[n]able all  [t]oggle all  [Space] next host
            [g/G] columns  [f/F] font  s[o]rt  [m]inimise  [h]ide  [s]end text  mo[v]e to screen  [d]ump scrollback  [k] clear scrollback  e[x]it
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
