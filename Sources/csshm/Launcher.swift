// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

/// What runs when the user types `csshm`: it works out the session, writes it
/// to a private directory and opens the master window, which does the rest.
enum Launcher {
    static let usage = """
    usage: csshm [options] [host or cluster ...]
           csshm [options] --addresses FILE
           command | csshm [options]

    Opens one Terminal window per host, tiled across your monitors, plus a red
    master window. Typing in the master window goes to every host; typing in a
    host window goes only to that host. Press Ctrl-A in the master for the menu.

    HOSTS
      host                    10.0.0.5 or web1 (a name from ~/.ssh/config works)
      host:port               10.0.0.5:2222
      user@host[:port]        ubuntu@10.0.0.5
      user,host[:port]        ubuntu,10.0.0.5
      user@host,KEYFILE       a private key for this host only
      user,host,KEYFILE       the same; ",host,KEYFILE" keeps the --login user
      [ipv6]:port             [fe80::1]:2222 (a bare fe80::1 also works)

      A user written with a host wins over --login. Hosts can be given as
      arguments, in files, or on standard input when no other hosts are named.
      A cluster is a named group of hosts from the settings file.

    OPTIONS
      -l, --login USER        user to log in as, for hosts that do not name one
          --ssh_args ARGS     extra arguments for ssh, as one quoted string,
                              for example "-i ~/.ssh/key -o ConnectTimeout=5"
          --screen SPEC       monitors to use: 2, 2-4 (2, 3 and 4) or 1,3.
                              1 is the primary display and the default.
          --hosts FILE        read hosts from FILE, one per line; "-" means
          --addresses FILE    standard input. "#" starts a comment. Text after
                              a host is a command to run on that host. Both
                              names mean the same and may be repeated.
          --remote_command CMD  command to run on every host
          --ssh COMMAND       program to run instead of ssh
      -x, --tile_x N          fixed number of columns on each monitor
      -y, --tile_y N          fixed number of rows on each monitor
          --profile NAME      Terminal profile for the host windows
          --master_profile NAME  Terminal profile for the master window
          --font_size N       font size for the host windows
          --menu_key KEY      key that opens the menu, for example ctrl-b
          --config FILE       settings file to read instead of the default
          --list_clusters     print the cluster names and exit
          --debug             show the command each window runs, and leave
                              windows open when their session ends
          --update            replace this csshm with the latest release
      -h, --help              show this help
      -v, --version           show the version

      Options may be written --name VALUE or --name=VALUE, with one dash or
      two, and shortened to any unique prefix (--scr 2).

    MENU (Ctrl-A in the master window; Esc goes back)
      Ctrl-A   send a real Ctrl-A to the hosts
      r        re-tile, and bring back hidden or minimised windows
      c        add a host
      e        pick windows: arrows or h/j/k/l to move, then e enable,
               d disable, t toggle, o only this one, O only this one, zoomed
      n  t     enable all / toggle all
      Space    with one host enabled, move on to the next
      g  G     more / fewer columns
      f  F     smaller / larger text in the host windows
      o        sort the windows by hostname or id
      m  h     minimise / hide the host windows
      Ctrl-H   hide the host windows and minimise the master
      s        type each host's own name or id into it
      v        move the session to other monitors
      d        save every window's scrollback to files
      x        close everything and exit

    SETTINGS FILE (~/.config/csshm/config.toml, optional)
      login = "ubuntu"                  ssh_args = "-i ~/.ssh/key"
      screen = "2-3"                    profile = "Basic"
      font_size = 10                    menu_key = "ctrl-b"

      [clusters]
      web = ["web1", "web2", "admin@web3"]
      prod = "~/servers.txt"            # a hosts file
      all = ["web", "prod"]             # clusters can hold clusters

      Anything given on the command line wins over the file. The README
      lists every setting, including colours.

    EXAMPLES
      csshm web1 web2 web3
      csshm web                         # a cluster from the settings file
      csshm --login ubuntu --ssh_args "-i ~/.ssh/key" --addresses servers.txt
      csshm --screen 2-3 --login ubuntu $(< servers.txt)
      cat servers.txt | csshm --login ubuntu

    A session that ends closes its window and the rest re-tile. If ssh itself
    fails, the window stays open in grey so the error can be read: press Enter
    in it to close it. csshm never stores or sends passwords.

    Full documentation: https://github.com/anarchy89/csshm
    """

    static func run(_ options: Options) -> Never {
        for warning in options.warnings { warn(warning) }

        // The windows belong to the logged-in user; refuse to run as someone else.
        var runningAsSomeoneElse = geteuid() == 0 && ProcessInfo.processInfo.environment["SUDO_USER"] != nil
        if let tty = controllingTTY() {
            var info = stat()
            if stat(tty, &info) == 0, info.st_uid != geteuid() { runningAsSomeoneElse = true }
        }
        if runningAsSomeoneElse {
            die("must be run as the logged in user, not with sudo")
        }

        let settings = loadSettings(options)
        if options.listClusters {
            print(settings.clusters.keys.sorted().joined(separator: " "))
            exit(0)
        }

        var entries: [(name: String, command: String?)] = options.hosts.map { ($0, nil) }
        var files = options.hostsFiles
        if entries.isEmpty && files.isEmpty && isatty(0) == 0 {
            files = ["-"]
        }
        for file in files {
            let data: Data
            if file == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else if let contents = FileManager.default.contents(atPath: (file as NSString).expandingTildeInPath) {
                data = contents
            } else {
                die("cannot read hosts file [\(file)]")
            }
            entries += HostsFile.parse(String(decoding: data, as: UTF8.self))
        }
        do {
            entries = try settings.expand(entries) { path in
                guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else {
                    throw ConfigError("cannot read hosts file [\(path)]")
                }
                return String(decoding: data, as: UTF8.self)
            }
        } catch {
            die("\(error)")
        }
        guard !entries.isEmpty else {
            warn("need at least one host")
            die("run \"csshm --help\" for how to give them", code: 2)
        }

        let hosts: [HostSpec]
        let sshArgs: [String]
        let screens: ScreenSpec
        // CSSHM_PRETEND_SCREENS and CSSHM_LOG are aids for testing.
        let environment = ProcessInfo.processInfo.environment
        let pretendScreens = environment["CSSHM_PRETEND_SCREENS"].flatMap { Int($0) }
        let backend = TerminalBackend(pretendScreens: pretendScreens)
        let profile = options.profile ?? settings.profile
        let masterProfile = options.masterProfile ?? settings.masterProfile
        let menuKey: UInt8?
        do {
            hosts = try entries.map { try HostSpec(parsing: $0.name, command: $0.command) }
            sshArgs = try ShellWords.split(options.sshArgs.isEmpty ? (settings.sshArgs ?? "") : options.sshArgs)
            screens = try ScreenSpec(parsing: options.screen.isEmpty ? (settings.screen ?? "") : options.screen)
            try screens.validate(available: max(1, try backend.screens().count))
            menuKey = try options.menuKey.map { try MenuKey.parse($0) } ?? settings.menuKey
            if let size = options.fontSize, size < 4 { throw ConfigError("--font_size must be 4 or more") }
            let wanted = [profile, masterProfile].compactMap { $0 }
            if !wanted.isEmpty {
                let known = try backend.profileNames()
                for name in wanted where !known.contains(name) {
                    throw ConfigError("Terminal has no profile named [\(name)]. It has: \(known.sorted().joined(separator: ", "))")
                }
            }
        } catch let error as ShellWordsError {
            die("--ssh_args: \(error)")
        } catch {
            die("\(error)")
        }

        let session = makeSessionDirectory()
        var config = SessionConfig(
            executable: executablePath(),
            hosts: hosts,
            login: options.login ?? settings.login,
            ssh: options.ssh ?? settings.ssh ?? "ssh",
            sshArgs: sshArgs,
            remoteCommand: options.remoteCommand.isEmpty ? (settings.remoteCommand ?? "") : options.remoteCommand,
            screens: screens.screens,
            tileX: options.tileX > 0 ? options.tileX : (settings.tileX ?? 0),
            tileY: options.tileY > 0 ? options.tileY : (settings.tileY ?? 0),
            masterHeight: settings.masterHeight ?? 87,
            debug: options.debug,
            logFile: environment["CSSHM_LOG"],
            pretendScreens: pretendScreens)
        config.menuKey = menuKey
        config.profile = profile
        config.masterProfile = masterProfile
        config.fontSize = options.fontSize ?? settings.fontSize
        config.colors = settings.colors
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: URL(fileURLWithPath: session + "/config.json"), options: .atomic)
            try backend.openWindows(commands: [
                SessionConfig.roleCommand(executable: config.executable, role: "master", session: session),
            ])
            try? backend.activate()
        } catch {
            try? FileManager.default.removeItem(atPath: session)
            die("\(error)")
        }
        exit(0)
    }

    static let defaultSettingsPath = "~/.config/csshm/config.toml"

    /// Reads the settings file: the one named with --config, which must
    /// exist, or else the default one if it is there.
    private static func loadSettings(_ options: Options) -> UserConfig {
        let path = ((options.config ?? defaultSettingsPath) as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            if options.config != nil { die("cannot read settings file [\(path)]") }
            return UserConfig()
        }
        do {
            return try UserConfig(parsing: String(decoding: data, as: UTF8.self))
        } catch {
            die("\(path): \(error)")
        }
    }

    /// A private directory for the session's socket and settings. The socket
    /// path has to fit in a unix socket address, so prefer a short location.
    private static func makeSessionDirectory() -> String {
        let name = "csshm-\(getuid())-\(getpid())-\(UInt32.random(in: 0...0xffff))"
        var bases = [NSTemporaryDirectory(), "/tmp/"]
        if (bases[0] + name + "/sock").utf8.count > 100 { bases.removeFirst() }
        for base in bases {
            let path = (base as NSString).appendingPathComponent(name)
            if mkdir(path, 0o700) == 0 { return path }
        }
        die("cannot create a session directory")
    }

    private static func executablePath() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
