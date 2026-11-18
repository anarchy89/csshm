// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CsshmCore

final class HostSpecTests: XCTestCase {
    private func parts(_ text: String) throws -> [String?] {
        let spec = try HostSpec(parsing: text)
        return [spec.user, spec.host, spec.port]
    }

    func testClassicForms() throws {
        XCTAssertEqual(try parts("10.0.0.1"), [nil, "10.0.0.1", nil])
        XCTAssertEqual(try parts("web1:2222"), [nil, "web1", "2222"])
        XCTAssertEqual(try parts("admin@web1"), ["admin", "web1", nil])
        XCTAssertEqual(try parts("admin@web1:2222"), ["admin", "web1", "2222"])
    }

    func testCommaForms() throws {
        XCTAssertEqual(try parts("ubuntu,10.0.0.1"), ["ubuntu", "10.0.0.1", nil])
        XCTAssertEqual(try parts("ubuntu,10.0.0.1:2222"), ["ubuntu", "10.0.0.1", "2222"])
    }

    func testKeyPerHost() throws {
        let three = try HostSpec(parsing: "ubuntu,10.0.0.1,~/.ssh/key-a")
        XCTAssertEqual([three.user, three.host, three.port, three.key], ["ubuntu", "10.0.0.1", nil, "~/.ssh/key-a"])
        XCTAssertEqual(three.original, "ubuntu,10.0.0.1", "the key is not part of the window's name")

        let at = try HostSpec(parsing: "admin@10.0.0.3:2200,/keys/b.pem")
        XCTAssertEqual([at.user, at.host, at.port, at.key], ["admin", "10.0.0.3", "2200", "/keys/b.pem"])
        XCTAssertEqual(at.original, "admin@10.0.0.3:2200")

        // An empty user means "whoever --login says".
        let noUser = try HostSpec(parsing: ",10.0.0.4,~/.ssh/key-c")
        XCTAssertEqual([noUser.user, noUser.host, noUser.key], [nil, "10.0.0.4", "~/.ssh/key-c"])
        XCTAssertEqual(noUser.original, "10.0.0.4")

        XCTAssertNil(try HostSpec(parsing: "ubuntu,10.0.0.1").key)
        XCTAssertNil(try HostSpec(parsing: "ubuntu@10.0.0.1").key)
    }

    func testKeyGoesBeforeTheSharedArguments() throws {
        let shared = try ShellWords.split("-i ~/.ssh/ssh-key -o StrictHostKeyChecking=no")
        XCTAssertEqual(
            try HostSpec(parsing: ",10.0.0.4,~/.ssh/key-c").command(ssh: "ssh", sshArgs: shared, login: "ubuntu", remoteCommand: ""),
            ["ssh", "-i", "~/.ssh/key-c", "-i", "~/.ssh/ssh-key", "-o", "StrictHostKeyChecking=no", "-l", "ubuntu", "10.0.0.4"])
        XCTAssertEqual(
            try HostSpec(parsing: "admin,10.0.0.3,/keys/b.pem").command(ssh: "ssh", sshArgs: [], login: "ubuntu", remoteCommand: ""),
            ["ssh", "-i", "/keys/b.pem", "-l", "admin", "10.0.0.3"])
    }

    func testHostsFileWithKeys() throws {
        let lines = HostsFile.parse("ubuntu,10.0.0.1,~/.ssh/key-a\nadmin@10.0.0.3,~/.ssh/key-b  uptime\n10.0.0.5\n")
        let specs = try lines.map { try HostSpec(parsing: $0.name, command: $0.command) }
        XCTAssertEqual(specs.map(\.key), ["~/.ssh/key-a", "~/.ssh/key-b", nil])
        XCTAssertEqual(specs.map(\.command), [nil, "uptime", nil])
    }

    func testIPv6() throws {
        XCTAssertEqual(try parts("fe80::1"), [nil, "fe80::1", nil])
        XCTAssertEqual(try parts("root@[fe80::1]:2222"), ["root", "fe80::1", "2222"])
        XCTAssertEqual(try parts("[::1]"), [nil, "::1", nil])
    }

    func testRejectsBadHosts() {
        for bad in ["", "   ", "@host", "host:", "host:abc", "-oProxyCommand=x", "a b", "[::1", ",host",
                    "user,host,", "user,host,key,extra", "user,other@host,key", "user@host,", ",,key"] {
            XCTAssertThrowsError(try HostSpec(parsing: bad), bad)
        }
    }

    /// Host names end up in window titles and on ssh's command line, so
    /// anything a terminal or a shell would act on is refused.
    func testRejectsControlAndShellCharacters() {
        let bad = [
            "ev\u{1b}]0;title\u{07}il",          // terminal escape sequence
            "host\u{07}",                          // bell
            "host\u{7f}",
            "host\u{9b}31m",                       // C1 control
            "host;reboot", "host$(id)", "host`id`", "host|nc", "host&", "a/b", "host'x", "host\"x", "host>f",
            "us\u{1b}[31mer@host", "us;er@host", "us$er,host", "-oX@host",
            "user,host,ke\u{1b}y", "user,host,-oProxyCommand=x",
        ]
        for text in bad {
            XCTAssertThrowsError(try HostSpec(parsing: text), text.debugDescription)
        }
        XCTAssertThrowsError(try HostSpec(parsing: "web1", command: "echo \u{1b}[2J")) { error in
            XCTAssertEqual(error as? HostSpecError, .invalidCommand(host: "web1"))
            XCTAssertEqual("\(error)", "Bad command for host [web1]: it contains a control character")
        }
        // A bad host with a bad command is reported as the bad host.
        XCTAssertThrowsError(try HostSpec(parsing: "web;1", command: "echo \u{1b}[2J")) { error in
            XCTAssertEqual(error as? HostSpecError, .invalid("web;1"))
        }
    }

    func testErrorMessageDoesNotRepeatControlCharacters() {
        XCTAssertEqual(HostSpecError.invalid("ev\u{1b}]0;x\u{07}il").description, "Bad host [ev?]0;x?il]")
    }

    func testUsualNamesStillPass() throws {
        for text in ["web-1.example.com", "db_02", "10.0.0.1", "fe80::1%en0", "[fe80::1%en0]:22", "münchen.example",
                     "first.last@host", "DOMAIN\\user@host", "svc+deploy@host", "me@corp.com@host",
                     "user,host,~/.ssh/id_ed25519", "user,host,/keys/my key.pem".replacingOccurrences(of: " ", with: "_")] {
            XCTAssertNoThrow(try HostSpec(parsing: text), text)
        }
        XCTAssertNoThrow(try HostSpec(parsing: "web1", command: "tail -f /var/log/syslog | grep -v 'x;y'"))
    }

    func testCommandMatchesTheOwnersScript() throws {
        let args = try ShellWords.split("-i ~/.ssh/ssh-key -o StrictHostKeyChecking=no")
        let spec = try HostSpec(parsing: "10.1.2.3")
        XCTAssertEqual(
            spec.command(ssh: "ssh", sshArgs: args, login: "ubuntu", remoteCommand: ""),
            ["ssh", "-i", "~/.ssh/ssh-key", "-o", "StrictHostKeyChecking=no", "-l", "ubuntu", "10.1.2.3"])
    }

    func testPerHostUserAndPortOverrideLogin() throws {
        let spec = try HostSpec(parsing: "admin,10.1.2.3:2200")
        XCTAssertEqual(
            spec.command(ssh: "ssh", sshArgs: [], login: "ubuntu", remoteCommand: "uptime"),
            ["ssh", "-l", "admin", "-p", "2200", "10.1.2.3", "uptime"])
    }

    func testPerHostCommandOverridesRemoteCommand() throws {
        let spec = try HostSpec(parsing: "web1", command: "tail -f /var/log/syslog")
        XCTAssertEqual(
            spec.command(ssh: "/usr/bin/ssh", sshArgs: [], login: nil, remoteCommand: "uptime"),
            ["/usr/bin/ssh", "web1", "tail -f /var/log/syslog"])
    }

    func testHostsFile() {
        let text = """
        # servers
        10.0.0.1
          ubuntu@10.0.0.2   # trailing comment

        web3  tail -f /var/log/syslog
        admin,10.0.0.4\t uptime
        """
        let hosts = HostsFile.parse(text)
        XCTAssertEqual(hosts.map(\.name), ["10.0.0.1", "ubuntu@10.0.0.2", "web3", "admin,10.0.0.4"])
        XCTAssertEqual(hosts.map(\.command), [nil, nil, "tail -f /var/log/syslog", "uptime"])
    }
}

final class ShellWordsTests: XCTestCase {
    func testSplit() throws {
        XCTAssertEqual(try ShellWords.split(""), [])
        XCTAssertEqual(try ShellWords.split("  -a   -b  "), ["-a", "-b"])
        XCTAssertEqual(try ShellWords.split("-o 'ProxyCommand ssh -W %h:%p jump'"), ["-o", "ProxyCommand ssh -W %h:%p jump"])
        XCTAssertEqual(try ShellWords.split(#"-o "User name" a\ b ''"#), ["-o", "User name", "a b", ""])
        XCTAssertEqual(try ShellWords.split(#""a\"b" 'c"d' "e\f""#), [#"a"b"#, #"c"d"#, #"e\f"#])
        XCTAssertEqual(try ShellWords.split("-i ~/.ssh/key"), ["-i", "~/.ssh/key"], "tilde is left for ssh")
    }

    func testUnbalancedQuote() {
        XCTAssertThrowsError(try ShellWords.split("-o 'oops"))
        XCTAssertThrowsError(try ShellWords.split("-o \"oops"))
    }

    func testQuoteRoundTrips() throws {
        for word in ["plain", "with space", "it's", "/Volumes/My Shared Files/csshm", "$HOME \"x\" `y`", ""] {
            XCTAssertEqual(try ShellWords.split(ShellWords.quote(word)), [word])
        }
    }

    func testRoleCommand() {
        let line = SessionConfig.roleCommand(executable: "/opt/my tools/csshm", role: "slave", session: "/tmp/s", slaveID: 7)
        XCTAssertEqual(line, " exec '/opt/my tools/csshm' --slave --session '/tmp/s' --slaveid 7")
    }
}

final class VersionTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(Version.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(Version.isNewer("0.2", than: "0.1.9"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertTrue(Version.isNewer("0.10.0", than: "0.9.0"), "numbers, not text")
        XCTAssertFalse(Version.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Version.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(Version.isNewer("0.1.0", than: "0.1.1"))
        XCTAssertFalse(Version.isNewer("nonsense", than: "0.1.0"))
    }
}

final class OptionsTests: XCTestCase {
    /// The owner's wrapper script, unchanged.
    func testOwnersInvocation() throws {
        let options = try Options(arguments: [
            "--screen", "3-4", "--login", "ubuntu",
            "--ssh_args", "-i ~/.ssh/ssh-key -o StrictHostKeyChecking=no",
            "10.0.0.1", "10.0.0.2", "10.0.0.3",
        ])
        XCTAssertEqual(options.screen, "3-4")
        XCTAssertEqual(options.login, "ubuntu")
        XCTAssertEqual(options.sshArgs, "-i ~/.ssh/ssh-key -o StrictHostKeyChecking=no")
        XCTAssertEqual(options.hosts, ["10.0.0.1", "10.0.0.2", "10.0.0.3"])
        XCTAssertTrue(options.warnings.isEmpty)
    }

    func testShortFormsEqualsAndSingleDash() throws {
        let options = try Options(arguments: ["-l", "root", "-x", "4", "--tile_y=2", "-ssh", "mosh", "host1", "--debug"])
        XCTAssertEqual(options.login, "root")
        XCTAssertEqual(options.tileX, 4)
        XCTAssertEqual(options.tileY, 2)
        XCTAssertEqual(options.ssh, "mosh")
        XCTAssertEqual(options.hosts, ["host1"])
        XCTAssertEqual(options.debug, 1)
    }

    func testAbbreviations() throws {
        XCTAssertEqual(try Options(arguments: ["--scr", "2", "h"]).screen, "2")
        XCTAssertEqual(try Options(arguments: ["--remote", "uptime", "h"]).remoteCommand, "uptime")
        XCTAssertFalse(try Options(arguments: ["--remote", "uptime", "h"]).keepOpen)
        XCTAssertFalse(try Options(arguments: ["--remote_command", "uptime", "h"]).keepOpen)
        let kept = try Options(arguments: ["--remote_command_keepalive", "df -h", "h"])
        XCTAssertEqual(kept.remoteCommand, "df -h")
        XCTAssertTrue(kept.keepOpen)
        XCTAssertEqual(kept.hosts, ["h"])
        XCTAssertTrue(try Options(arguments: ["--remote_command_k=uptime", "h"]).keepOpen)
        XCTAssertThrowsError(try Options(arguments: ["--s", "2"])) { error in
            guard case .ambiguousOption = error as? OptionsError else { return XCTFail("\(error)") }
        }
    }

    func testDebugTakesAnOptionalNumber() throws {
        XCTAssertEqual(try Options(arguments: ["--debug", "2", "host"]).debug, 2)
        let options = try Options(arguments: ["--debug", "host"])
        XCTAssertEqual(options.debug, 1)
        XCTAssertEqual(options.hosts, ["host"])
    }

    func testHostsFilesRepeatAndDashMeansStdin() throws {
        let options = try Options(arguments: ["--hosts", "a.txt", "--hosts", "-"])
        XCTAssertEqual(options.hostsFiles, ["a.txt", "-"])
    }

    func testAddressesIsAnotherNameForHosts() throws {
        let options = try Options(arguments: ["--login", "ubuntu", "--addresses", "/Volumes/data/addresses.txt"])
        XCTAssertEqual(options.hostsFiles, ["/Volumes/data/addresses.txt"])
        XCTAssertEqual(options.login, "ubuntu")
        XCTAssertEqual(try Options(arguments: ["--addresses=a.txt"]).hostsFiles, ["a.txt"])
    }

    func testErrors() {
        XCTAssertThrowsError(try Options(arguments: ["--nope"])) { XCTAssertEqual($0 as? OptionsError, .unknownOption("--nope")) }
        XCTAssertThrowsError(try Options(arguments: ["--login"])) { XCTAssertEqual($0 as? OptionsError, .missingValue("--login")) }
        XCTAssertThrowsError(try Options(arguments: ["-x", "wide"])) {
            XCTAssertEqual($0 as? OptionsError, .badNumber(option: "-x", value: "wide"))
        }
        XCTAssertThrowsError(try Options(arguments: ["--help=1"]))
    }

    func testDroppedCsshXOptionsAreAcceptedWithAWarning() throws {
        let options = try Options(arguments: ["--ping_test", "--session_max", "500", "--no_growl", "host1"])
        XCTAssertEqual(options.hosts, ["host1"])
        XCTAssertEqual(options.warnings.count, 3)
    }

    func testProfileFontMenuKeyAndConfigOptions() throws {
        let options = try Options(arguments: [
            "--profile", "Small", "--master_profile=Pro", "--font_size", "9", "--menu_key", "ctrl-b",
            "--config", "~/my.toml", "web",
        ])
        XCTAssertEqual(options.profile, "Small")
        XCTAssertEqual(options.masterProfile, "Pro")
        XCTAssertEqual(options.fontSize, 9)
        XCTAssertEqual(options.menuKey, "ctrl-b")
        XCTAssertEqual(options.config, "~/my.toml")
        XCTAssertEqual(options.hosts, ["web"])
        XCTAssertTrue(options.warnings.isEmpty)
        // Re-tiling after a window closes: on command unless asked otherwise.
        XCTAssertNil(options.retile)
        XCTAssertEqual(try Options(arguments: ["--retile", "auto", "web"]).retile, "auto")
        XCTAssertEqual(try RetileMode(parsing: "manual"), .manual)
        XCTAssertEqual(try RetileMode(parsing: "Auto"), .auto)
        XCTAssertThrowsError(try RetileMode(parsing: "sometimes"))
        XCTAssertEqual(try UserConfig(parsing: "retile = \"auto\"").retile, "auto")
        XCTAssertThrowsError(try UserConfig(parsing: "retile = \"never\""))
        // The master's monitor: not given unless asked for.
        XCTAssertNil(options.masterScreen)
        XCTAssertEqual(try Options(arguments: ["--master_screen", "3", "web"]).masterScreen, 3)
        XCTAssertEqual(try UserConfig(parsing: "master_screen = 2").masterScreen, 2)
        XCTAssertThrowsError(try UserConfig(parsing: "master_screen = 0"))
        // The csshX names for profiles still work.
        let old = try Options(arguments: ["--sss", "Quiet", "--mss", "Loud"])
        XCTAssertEqual([old.profile, old.masterProfile], ["Quiet", "Loud"])
        XCTAssertNil(try Options(arguments: ["a"]).ssh)
        XCTAssertTrue(try Options(arguments: ["--list_clusters"]).listClusters)
        XCTAssertTrue(try Options(arguments: ["--update"]).update)
    }

    func testDoubleDashEndsOptions() throws {
        XCTAssertEqual(try Options(arguments: ["--", "--login"]).hosts, ["--login"])
    }

    func testRoles() throws {
        let options = try Options(arguments: ["--slave", "--session", "/tmp/x y", "--slaveid", "12"])
        XCTAssertTrue(options.slave)
        XCTAssertEqual(options.session, "/tmp/x y")
        XCTAssertEqual(options.slaveID, 12)
    }
}
