// SPDX-License-Identifier: GPL-3.0-or-later

/// Everything the master needs to run a session. The launcher writes it to
/// the session directory and the master reads it, so no settings travel on
/// the command line typed into each new window.
public struct SessionConfig: Codable, Equatable, Sendable {
    /// Absolute path of the csshm binary, used to start each host window.
    public var executable: String
    public var hosts: [HostSpec]
    public var login: String?
    public var ssh: String
    /// `--ssh_args`, already split into words.
    public var sshArgs: [String]
    public var remoteCommand: String
    /// 1-based screen numbers.
    public var screens: [Int]
    public var tileX: Int
    public var tileY: Int
    public var masterHeight: Int
    public var debug: Int
    /// Where the master writes a trace of what it does, if anywhere.
    public var logFile: String?
    /// For testing on one display: treat it as this many screens side by side.
    public var pretendScreens: Int?
    /// The byte the menu key sends; Ctrl-A when absent.
    public var menuKey: UInt8?
    /// Terminal profile for the host windows, and for the master window.
    public var profile: String?
    public var masterProfile: String?
    /// Font size for the host windows.
    public var fontSize: Int?
    public var colors = SessionColors()

    public init(executable: String, hosts: [HostSpec], login: String?, ssh: String, sshArgs: [String],
                remoteCommand: String, screens: [Int], tileX: Int, tileY: Int, masterHeight: Int = 87, debug: Int, logFile: String? = nil, pretendScreens: Int? = nil) {
        self.executable = executable
        self.hosts = hosts
        self.login = login
        self.ssh = ssh
        self.sshArgs = sshArgs
        self.remoteCommand = remoteCommand
        self.screens = screens
        self.tileX = tileX
        self.tileY = tileY
        self.masterHeight = masterHeight
        self.debug = debug
        self.logFile = logFile
        self.pretendScreens = pretendScreens
    }

    /// The line typed into a new window's shell to start a role there. It
    /// begins with a space and uses `exec`, which keeps it out of shell
    /// history in the common configurations.
    public static func roleCommand(executable: String, role: String, session: String, slaveID: Int? = nil) -> String {
        var words = ["exec", ShellWords.quote(executable), "--" + role, "--session", ShellWords.quote(session)]
        if let id = slaveID {
            words += ["--slaveid", String(id)]
        }
        return " " + words.joined(separator: " ")
    }
}
