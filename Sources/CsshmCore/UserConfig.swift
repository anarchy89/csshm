// SPDX-License-Identifier: GPL-3.0-or-later

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The colours csshm paints windows with.
public struct SessionColors: Codable, Equatable, Sendable {
    public var masterBackground = Palette.masterBackground
    public var masterText = Palette.masterForeground
    public var disabledText = Palette.disabledForeground
    public var selectedBackground = Palette.selectedBackground

    public init() {}

    /// The colours a host window should show. `nil` means "the window's own
    /// original colour".
    public func hostColors(inactive: Bool, selected: Bool) -> (foreground: RGB?, background: RGB?) {
        (inactive ? disabledText : nil, selected ? selectedBackground : nil)
    }
}

extension RGB {
    /// Parses a web colour such as `#940000` or `940000`.
    public init?(hex text: String) {
        var digits = Substring(text)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        // Spread each 8-bit channel over 16 bits (0xff becomes 0xffff).
        self.init(UInt16((value >> 16) & 0xff) * 257, UInt16((value >> 8) & 0xff) * 257, UInt16(value & 0xff) * 257)
    }
}

/// The key that opens the menu in the master window.
public enum MenuKey {
    /// Parses `ctrl-b`, `Ctrl+B` or `^B` into the byte that key sends.
    public static func parse(_ text: String) throws -> UInt8 {
        let lower = text.lowercased().filter { !$0.isWhitespace }
        var name = Substring(lower)
        for prefix in ["ctrl-", "ctrl+", "control-", "control+", "^"] where name.hasPrefix(prefix) {
            name = name.dropFirst(prefix.count)
            if name.count == 1, let letter = name.first, let ascii = letter.asciiValue, letter.isLetter {
                // Keys the terminal already uses for Tab, Enter and Backspace cannot be the menu key.
                guard !"ijmh".contains(letter) else { break }
                return ascii & 0x1f
            }
            break
        }
        throw ConfigError("Bad menu key [\(text)]: use a form like ctrl-b (any letter except h, i, j and m)")
    }

    /// The name shown in prompts, e.g. `Ctrl-A`.
    public static func name(_ byte: UInt8) -> String {
        "Ctrl-" + String(UnicodeScalar(byte | 0x40))
    }
}

/// A named group of hosts.
public enum Cluster: Equatable, Sendable {
    /// Hosts, or the names of other clusters.
    case hosts([String])
    /// A hosts file, in the same format `--addresses` reads.
    case file(String)
}

/// Settings from the user's config file. Everything is optional; whatever is
/// given on the command line wins.
public struct UserConfig: Equatable, Sendable {
    public var login: String?
    public var sshArgs: String?
    public var ssh: String?
    public var screen: String?
    public var remoteCommand: String?
    public var tileX: Int?
    public var tileY: Int?
    public var menuKey: UInt8?
    public var masterHeight: Int?
    public var profile: String?
    public var masterProfile: String?
    public var fontSize: Int?
    public var colors = SessionColors()
    public var clusters: [String: Cluster] = [:]

    public init() {}

    public init(parsing text: String) throws {
        let root: [String: TomlValue]
        do {
            root = try Toml.parse(text)
        } catch let error as TomlError {
            throw ConfigError("\(error)")
        }

        func string(_ key: String, _ value: TomlValue) throws -> String {
            guard case .string(let text) = value else { throw ConfigError("\(key) must be text in quotes") }
            return text
        }
        func integer(_ key: String, _ value: TomlValue, atLeast minimum: Int) throws -> Int {
            guard case .integer(let number) = value, number >= minimum else {
                throw ConfigError("\(key) must be a whole number, \(minimum) or more")
            }
            return number
        }

        for (key, value) in root.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "login": login = try string(key, value)
            case "ssh_args": sshArgs = try string(key, value)
            case "ssh": ssh = try string(key, value)
            case "remote_command": remoteCommand = try string(key, value)
            case "profile": profile = try string(key, value)
            case "master_profile": masterProfile = try string(key, value)
            case "menu_key": menuKey = try MenuKey.parse(try string(key, value))
            case "screen":
                if case .integer(let number) = value { screen = String(number) } else { screen = try string(key, value) }
                do {
                    _ = try ScreenSpec(parsing: screen!)
                } catch {
                    throw ConfigError("screen: \(error)")
                }
            case "tile_x": tileX = try integer(key, value, atLeast: 0)
            case "tile_y": tileY = try integer(key, value, atLeast: 0)
            case "master_height": masterHeight = try integer(key, value, atLeast: 20)
            case "font_size": fontSize = try integer(key, value, atLeast: 4)
            case "colors":
                guard case .table(let table) = value else { throw ConfigError("colors must be a [colors] section") }
                for (name, entry) in table.sorted(by: { $0.key < $1.key }) {
                    guard let color = RGB(hex: try string("colors.\(name)", entry)) else {
                        throw ConfigError("colors.\(name) must be a colour like \"#940000\"")
                    }
                    switch name {
                    case "master_background": colors.masterBackground = color
                    case "master_text": colors.masterText = color
                    case "disabled_text": colors.disabledText = color
                    case "selected_background": colors.selectedBackground = color
                    default: throw ConfigError("unknown setting colors.\(name)")
                    }
                }
            case "clusters":
                guard case .table(let table) = value else { throw ConfigError("clusters must be a [clusters] section") }
                for (name, entry) in table {
                    switch entry {
                    case .string(let path):
                        clusters[name] = .file(path)
                    case .array(let items):
                        clusters[name] = .hosts(try items.map { try string("clusters.\(name)", $0) })
                    default:
                        throw ConfigError("clusters.\(name) must be a list of hosts or the path of a hosts file")
                    }
                }
            default:
                throw ConfigError("unknown setting \(key)")
            }
        }
    }

    /// Replaces cluster names with their hosts. Clusters may name other
    /// clusters. `readFile` returns the text of a hosts file.
    public func expand(_ entries: [(name: String, command: String?)],
                       readFile: (String) throws -> String) throws -> [(name: String, command: String?)] {
        var result: [(name: String, command: String?)] = []
        func add(_ entry: (name: String, command: String?), within: [String]) throws {
            guard let cluster = clusters[entry.name] else {
                result.append(entry)
                return
            }
            guard !within.contains(entry.name) else {
                throw ConfigError("cluster \(entry.name) includes itself")
            }
            let members: [(name: String, command: String?)]
            switch cluster {
            case .hosts(let names):
                members = names.map { ($0, nil) }
            case .file(let path):
                members = HostsFile.parse(try readFile(path))
            }
            for member in members {
                // A command given for the cluster applies to members without their own.
                try add((member.name, member.command ?? entry.command), within: within + [entry.name])
            }
        }
        for entry in entries { try add(entry, within: []) }
        return result
    }
}
