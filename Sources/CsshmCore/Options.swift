// SPDX-License-Identifier: GPL-3.0-or-later

public enum OptionsError: Error, Equatable, CustomStringConvertible {
    case unknownOption(String)
    case ambiguousOption(String, [String])
    case missingValue(String)
    case badNumber(option: String, value: String)
    case unexpectedValue(String)

    public var description: String {
        switch self {
        case .unknownOption(let name): return "Unknown option: \(name)"
        case .ambiguousOption(let name, let matches):
            return "Option \(name) is ambiguous (\(matches.map { "--" + $0 }.joined(separator: ", ")))"
        case .missingValue(let name): return "Option \(name) requires a value"
        case .badNumber(let option, let value): return "Option \(option) needs a number, not \"\(value)\""
        case .unexpectedValue(let name): return "Option \(name) does not take a value"
        }
    }
}

/// Command-line options. The names follow csshX so existing scripts keep
/// working: long options take one or two dashes, a value follows as the next
/// argument or after `=` and unique abbreviations are accepted.
public struct Options: Equatable, Sendable {
    public var login: String?
    public var screen: String = ""
    public var sshArgs: String = ""
    /// Program to run instead of ssh; `nil` when not given.
    public var ssh: String?
    public var remoteCommand: String = ""
    /// Keep each window open after its command ends (`--remote_command_keepalive`).
    public var keepOpen = false
    /// A command template to run in each window in place of ssh.
    public var command: String?
    public var tileX: Int = 0
    public var tileY: Int = 0
    public var hostsFiles: [String] = []
    /// `--env` values, each `NAME` or `NAME=VALUE`.
    public var env: [String] = []
    public var debug: Int = 0
    /// Settings file to read instead of the default one.
    public var config: String?
    /// Terminal profile for the host windows and for the master window.
    public var profile: String?
    public var masterProfile: String?
    public var fontSize: Int?
    /// `--retile`: "manual" or "auto". `nil` when not given.
    public var retile: String?
    /// Monitor for the master window (`--master_screen`); 1 when not given.
    public var masterScreen: Int?
    public var menuKey: String?
    public var listClusters: Bool = false
    public var update: Bool = false
    public var help: Bool = false
    public var version: Bool = false

    // Internal roles: the launcher starts the other two.
    public var master: Bool = false
    public var slave: Bool = false
    public var session: String?
    public var slaveID: Int?
    /// Internal: print the monitors' usable areas and exit.
    public var probeScreens: Bool = false

    /// Hosts given as plain arguments.
    public var hosts: [String] = []
    /// Notes about csshX options that are accepted but do nothing.
    public var warnings: [String] = []

    public init() {}

    private enum Kind { case flag, string, int, optionalInt }

    private struct Spec {
        let names: [String]
        let kind: Kind
        var ignored = false
    }

    private static let specs: [Spec] = [
        Spec(names: ["login", "l"], kind: .string),
        Spec(names: ["screen"], kind: .string),
        Spec(names: ["ssh_args"], kind: .string),
        Spec(names: ["ssh"], kind: .string),
        Spec(names: ["remote_command"], kind: .string),
        Spec(names: ["remote_command_keepalive"], kind: .string),
        Spec(names: ["command"], kind: .string),
        Spec(names: ["env"], kind: .string),
        Spec(names: ["tile_x", "x"], kind: .int),
        Spec(names: ["tile_y", "y"], kind: .int),
        Spec(names: ["hosts", "addresses"], kind: .string),
        Spec(names: ["debug"], kind: .optionalInt),
        Spec(names: ["help", "h"], kind: .flag),
        Spec(names: ["man", "m"], kind: .flag),
        Spec(names: ["version", "v"], kind: .flag),
        Spec(names: ["config", "c"], kind: .string),
        Spec(names: ["profile", "slave_settings_set", "sss"], kind: .string),
        Spec(names: ["master_profile", "master_settings_set", "mss"], kind: .string),
        Spec(names: ["master_screen"], kind: .int),
        Spec(names: ["retile"], kind: .string),
        Spec(names: ["font_size"], kind: .int),
        Spec(names: ["menu_key"], kind: .string),
        Spec(names: ["list_clusters"], kind: .flag),
        Spec(names: ["update"], kind: .flag),
        Spec(names: ["master"], kind: .flag),
        Spec(names: ["slave"], kind: .flag),
        Spec(names: ["session"], kind: .string),
        Spec(names: ["slaveid"], kind: .int),
        Spec(names: ["probe_screens"], kind: .flag),
        // csshX options with no equivalent here: accepted so old scripts run.
        Spec(names: ["space"], kind: .int, ignored: true),
        Spec(names: ["ping_test", "ping"], kind: .flag, ignored: true),
        Spec(names: ["ping_timeout"], kind: .int, ignored: true),
        Spec(names: ["session_max"], kind: .int, ignored: true),
        Spec(names: ["sorthosts"], kind: .flag, ignored: true),
        Spec(names: ["interleave", "i"], kind: .int, ignored: true),
        Spec(names: ["no_growl"], kind: .flag, ignored: true),
        Spec(names: ["sock"], kind: .string, ignored: true),
    ]

    private static func find(_ name: String, shown: String) throws -> Spec {
        if let exact = specs.first(where: { $0.names.contains(name) }) {
            return exact
        }
        let matches = specs.filter { $0.names[0].hasPrefix(name) }
        if matches.count == 1 { return matches[0] }
        // "--remote" still means --remote_command, though a longer option begins the same way.
        if let shortest = matches.min(by: { $0.names[0].count < $1.names[0].count }),
           matches.allSatisfy({ $0.names[0].hasPrefix(shortest.names[0]) }) {
            return shortest
        }
        if matches.isEmpty { throw OptionsError.unknownOption(shown) }
        throw OptionsError.ambiguousOption(shown, matches.map { $0.names[0] })
    }

    public init(arguments: [String]) throws {
        var index = 0
        var positionalOnly = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if positionalOnly || argument == "-" || !argument.hasPrefix("-") {
                hosts.append(argument)
                continue
            }
            if argument == "--" {
                positionalOnly = true
                continue
            }
            var body = Substring(argument).dropFirst()
            if body.hasPrefix("-") { body = body.dropFirst() }
            var inline: String?
            if let equals = body.firstIndex(of: "=") {
                inline = String(body[body.index(after: equals)...])
                body = body[..<equals]
            }
            let shown = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            let spec = try Options.find(String(body), shown: shown)

            var value: String?
            switch spec.kind {
            case .flag:
                if inline != nil { throw OptionsError.unexpectedValue(shown) }
            case .string, .int:
                if let inline = inline {
                    value = inline
                } else if index < arguments.count {
                    value = arguments[index]
                    index += 1
                } else {
                    throw OptionsError.missingValue(shown)
                }
            case .optionalInt:
                if let inline = inline {
                    value = inline
                } else if index < arguments.count, !arguments[index].isEmpty,
                          arguments[index].allSatisfy({ $0.isASCII && $0.isNumber }) {
                    value = arguments[index]
                    index += 1
                }
            }
            var number: Int?
            if spec.kind == .int || (spec.kind == .optionalInt && value != nil) {
                guard let parsed = Int(value ?? "") else {
                    throw OptionsError.badNumber(option: shown, value: value ?? "")
                }
                number = parsed
            }

            if spec.ignored {
                warnings.append("--\(spec.names[0]) is not supported and was ignored")
                continue
            }
            switch spec.names[0] {
            case "login": login = value
            case "screen": screen = value ?? ""
            case "ssh_args": sshArgs = value ?? ""
            case "ssh": ssh = value
            case "config": config = value
            case "profile": profile = value
            case "master_profile": masterProfile = value
            case "master_screen": masterScreen = number
            case "retile": retile = value
            case "font_size": fontSize = number
            case "menu_key": menuKey = value
            case "list_clusters": listClusters = true
            case "update": update = true
            case "remote_command": remoteCommand = value ?? ""
            case "remote_command_keepalive":
                remoteCommand = value ?? ""
                keepOpen = true
            case "command": command = value
            case "env": env.append(value ?? "")
            case "tile_x": tileX = max(0, number ?? 0)
            case "tile_y": tileY = max(0, number ?? 0)
            case "hosts": hostsFiles.append(value ?? "")
            case "debug": debug = number ?? (debug + 1)
            case "help", "man": help = true
            case "version": version = true
            case "master": master = true
            case "slave": slave = true
            case "session": session = value
            case "slaveid": slaveID = number
            case "probe_screens": probeScreens = true
            default: break
            }
        }
    }
}
