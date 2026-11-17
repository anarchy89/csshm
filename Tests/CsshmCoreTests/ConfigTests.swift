// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import CsshmCore

final class TomlTests: XCTestCase {
    func testValuesAndSections() throws {
        let parsed = try Toml.parse("""
        # a comment
        name = "ubuntu"   # trailing comment
        path = 'C:\\raw\\text'
        count = 12
        on = true
        quoted = "say \\"hi\\"\\n"

        [colors]
        red = "#ff0000"

        [clusters]
        web = ["web1", "web2",
               "web3",   # comments and line breaks are fine in lists
        ]
        empty = []
        """)
        XCTAssertEqual(parsed["name"], .string("ubuntu"))
        XCTAssertEqual(parsed["path"], .string("C:\\raw\\text"))
        XCTAssertEqual(parsed["count"], .integer(12))
        XCTAssertEqual(parsed["on"], .boolean(true))
        XCTAssertEqual(parsed["quoted"], .string("say \"hi\"\n"))
        XCTAssertEqual(parsed["colors"], .table(["red": .string("#ff0000")]))
        XCTAssertEqual(parsed["clusters"], .table([
            "web": .array([.string("web1"), .string("web2"), .string("web3")]),
            "empty": .array([]),
        ]))
    }

    func testNestedSections() throws {
        let parsed = try Toml.parse("[a.b]\nx = 1\n[a]\ny = 2\n")
        XCTAssertEqual(parsed["a"], .table(["b": .table(["x": .integer(1)]), "y": .integer(2)]))
    }

    func testErrorsNameTheLine() {
        let cases: [(String, Int)] = [
            ("a = 1\nb = oops\n", 2),
            ("a = \"unclosed\n", 1),
            ("a = 1\na = 2\n", 2),
            ("\n\n= 3\n", 3),
            ("a = [1, 2\n", 2),
            ("a = 1 2\n", 1),
            ("[section\n", 1),
        ]
        for (text, line) in cases {
            XCTAssertThrowsError(try Toml.parse(text), text) { error in
                XCTAssertEqual((error as? TomlError)?.line, line, text)
            }
        }
    }
}

final class UserConfigTests: XCTestCase {
    func testFullFile() throws {
        let config = try UserConfig(parsing: """
        login = "ubuntu"
        ssh_args = "-i ~/.ssh/key -o StrictHostKeyChecking=no"
        screen = "2-3"
        tile_x = 4
        menu_key = "ctrl-b"
        master_height = 120
        profile = "Small"
        master_profile = "Pro"
        font_size = 9

        [colors]
        master_background = "#003366"
        disabled_text = "777777"

        [clusters]
        web = ["web1", "ubuntu@web2:2222"]
        prod = "/Volumes/data/addresses.txt"
        """)
        XCTAssertEqual(config.login, "ubuntu")
        XCTAssertEqual(config.sshArgs, "-i ~/.ssh/key -o StrictHostKeyChecking=no")
        XCTAssertEqual(config.screen, "2-3")
        XCTAssertEqual(config.tileX, 4)
        XCTAssertEqual(config.menuKey, 0x02)
        XCTAssertEqual(config.masterHeight, 120)
        XCTAssertEqual(config.profile, "Small")
        XCTAssertEqual(config.masterProfile, "Pro")
        XCTAssertEqual(config.fontSize, 9)
        XCTAssertEqual(config.colors.masterBackground, RGB(0, 0x3333, 0x6666))
        XCTAssertEqual(config.colors.disabledText, RGB(0x7777, 0x7777, 0x7777))
        XCTAssertEqual(config.colors.selectedBackground, Palette.selectedBackground, "unset colours keep their defaults")
        XCTAssertEqual(config.clusters, ["web": .hosts(["web1", "ubuntu@web2:2222"]), "prod": .file("/Volumes/data/addresses.txt")])
    }

    func testEmptyFileChangesNothing() throws {
        XCTAssertEqual(try UserConfig(parsing: "# nothing here\n"), UserConfig())
    }

    func testScreenMayBeANumber() throws {
        XCTAssertEqual(try UserConfig(parsing: "screen = 3").screen, "3")
    }

    func testMistakesAreReported() {
        let bad = [
            "logn = \"ubuntu\"",               // misspelt setting
            "login = 5",                       // wrong kind of value
            "tile_x = \"four\"",
            "font_size = 2",
            "screen = \"two\"",
            "menu_key = \"ctrl-m\"",
            "[colors]\nmaster_background = \"red\"",
            "[colors]\nsky = \"#000000\"",
            "[clusters]\nweb = 5",
            "[clusters]\nweb = [1, 2]",
            "login = \"unclosed",
        ]
        for text in bad {
            XCTAssertThrowsError(try UserConfig(parsing: text), text) { XCTAssertTrue($0 is ConfigError, text) }
        }
    }

    func testMenuKey() throws {
        XCTAssertEqual(try MenuKey.parse("ctrl-a"), 0x01)
        XCTAssertEqual(try MenuKey.parse("Ctrl+B"), 0x02)
        XCTAssertEqual(try MenuKey.parse("^Z"), 0x1a)
        XCTAssertEqual(try MenuKey.parse(" control-t "), 0x14)
        XCTAssertEqual(MenuKey.name(0x01), "Ctrl-A")
        XCTAssertEqual(MenuKey.name(0x1a), "Ctrl-Z")
        for bad in ["b", "ctrl-", "ctrl-ab", "ctrl-1", "ctrl-m", "ctrl-i", "ctrl-j", "ctrl-h", "alt-a", ""] {
            XCTAssertThrowsError(try MenuKey.parse(bad), bad)
        }
    }

    func testHexColours() {
        XCTAssertEqual(RGB(hex: "#ffffff"), RGB(65535, 65535, 65535))
        XCTAssertEqual(RGB(hex: "940000"), RGB(0x9494, 0, 0))
        XCTAssertNil(RGB(hex: "#fff"))
        XCTAssertNil(RGB(hex: "red"))
    }

    private func names(_ config: UserConfig, _ given: [String], files: [String: String] = [:]) throws -> [String] {
        try config.expand(given.map { ($0, nil) }) { path in
            guard let text = files[path] else { throw ConfigError("cannot read hosts file [\(path)]") }
            return text
        }.map { $0.command == nil ? $0.name : "\($0.name) <\($0.command!)>" }
    }

    func testClusterExpansion() throws {
        var config = UserConfig()
        config.clusters = [
            "web": .hosts(["web1", "web2"]),
            "db": .hosts(["admin@db1"]),
            "all": .hosts(["web", "db", "extra"]),
            "prod": .file("/lists/prod.txt"),
        ]
        XCTAssertEqual(try names(config, ["web"]), ["web1", "web2"])
        XCTAssertEqual(try names(config, ["other", "db", "web"]), ["other", "admin@db1", "web1", "web2"], "order is kept")
        XCTAssertEqual(try names(config, ["all"]), ["web1", "web2", "admin@db1", "extra"], "clusters may hold clusters")
        XCTAssertEqual(
            try names(config, ["prod"], files: ["/lists/prod.txt": "# list\n10.0.0.1\nubuntu,10.0.0.2,~/.ssh/k  uptime\n"]),
            ["10.0.0.1", "ubuntu,10.0.0.2,~/.ssh/k <uptime>"])
        XCTAssertThrowsError(try names(config, ["prod"]), "a missing file is an error")
    }

    func testClusterThatIncludesItselfIsRefused() {
        var config = UserConfig()
        config.clusters = ["a": .hosts(["b"]), "b": .hosts(["a"])]
        XCTAssertThrowsError(try names(config, ["a"])) { error in
            XCTAssertEqual(error as? ConfigError, ConfigError("cluster a includes itself"))
        }
    }

    func testHostColoursFollowTheConfiguredPalette() {
        var colors = SessionColors()
        colors.disabledText = RGB(1, 2, 3)
        XCTAssertEqual(colors.hostColors(inactive: true, selected: false).foreground, RGB(1, 2, 3))
        XCTAssertNil(colors.hostColors(inactive: false, selected: false).foreground)
        XCTAssertEqual(colors.hostColors(inactive: false, selected: true).background, Palette.selectedBackground)
    }
}
