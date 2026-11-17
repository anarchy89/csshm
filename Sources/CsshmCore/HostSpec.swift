// SPDX-License-Identifier: GPL-3.0-or-later

public enum HostSpecError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let text): return "Bad host [\(text)]"
        }
    }
}

/// One host to connect to.
public struct HostSpec: Equatable, Codable, Sendable {
    /// The text the user gave, e.g. `ubuntu@10.0.0.5:2222`.
    public var original: String
    public var user: String?
    public var host: String
    public var port: String?
    /// A command to run on this host, from a hosts file.
    public var command: String?
    /// A private key file to use for this host only.
    public var key: String?

    public init(original: String, user: String? = nil, host: String, port: String? = nil, command: String? = nil, key: String? = nil) {
        self.original = original
        self.user = user
        self.host = host
        self.port = port
        self.command = command
        self.key = key
    }

    /// Parses one host. The forms are:
    ///
    ///     host            user@host            user,host
    ///     host:port       user@host:port       user,host:port
    ///
    /// Any of them may end with `,keyfile` to name a private key for that
    /// host: `user@host,key` or `user,host,key`. In the three-field form the
    /// user may be left empty (`,host,key`) to mean the default user. An IPv6
    /// address may be given bare (`fe80::1`) or in brackets with a port
    /// (`[fe80::1]:22`).
    public init(parsing text: String, command: String? = nil) throws {
        let trimmed = String(text.drop(while: { $0.isWhitespace }).reversed().drop(while: { $0.isWhitespace }).reversed())
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            throw HostSpecError.invalid(text)
        }

        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        var user: String?
        var rest: Substring
        var key: String?
        switch fields.count {
        case 1:
            rest = fields[0]
        case 2 where fields[0].contains("@"):
            rest = fields[0]
            key = String(fields[1])
        case 2:
            user = String(fields[0])
            rest = fields[1]
            if user!.isEmpty { throw HostSpecError.invalid(text) }
        case 3:
            user = fields[0].isEmpty ? nil : String(fields[0])
            rest = fields[1]
            key = String(fields[2])
        default:
            throw HostSpecError.invalid(text)
        }
        if let k = key, k.isEmpty { throw HostSpecError.invalid(text) }

        if let at = rest.lastIndex(of: "@") {
            // A user may be given once: before the comma or before the @.
            guard user == nil else { throw HostSpecError.invalid(text) }
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
            if user!.isEmpty { throw HostSpecError.invalid(text) }
        }
        // What windows are called: the host as written, without the key.
        let label = key == nil ? trimmed : String(trimmed[..<trimmed.lastIndex(of: ",")!])

        var host: String
        var port: String?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw HostSpecError.invalid(text) }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                port = String(after.dropFirst())
            } else if !after.isEmpty {
                throw HostSpecError.invalid(text)
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        } else {
            // No colon, or several: a plain name or a bare IPv6 address.
            host = String(rest)
        }

        guard !host.isEmpty, !host.hasPrefix("-") else { throw HostSpecError.invalid(text) }
        if let p = port {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw HostSpecError.invalid(text) }
        }

        self.original = label.hasPrefix(",") ? String(label.dropFirst()) : label
        self.key = key
        self.user = user
        self.host = host
        self.port = port
        self.command = (command?.isEmpty ?? true) ? nil : command
    }

    /// The argument list that starts this host's session.
    public func command(ssh: String, sshArgs: [String], login: String?, remoteCommand: String) -> [String] {
        var argv = [ssh]
        // Before the shared arguments, so ssh offers this host's key first.
        if let key = key {
            argv += ["-i", key]
        }
        argv += sshArgs
        if let user = user ?? login, !user.isEmpty {
            argv += ["-l", user]
        }
        if let port = port {
            argv += ["-p", port]
        }
        argv.append(host)
        let remote = command ?? remoteCommand
        if !remote.isEmpty {
            argv.append(remote)
        }
        return argv
    }
}

public enum HostsFile {
    /// Reads a hosts list: one host per line, optionally followed by a
    /// command to run on it. `#` starts a comment. Blank lines are skipped.
    public static func parse(_ text: String) -> [(name: String, command: String?)] {
        var result: [(name: String, command: String?)] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = line[..<hash]
            }
            line = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.isEmpty else { continue }
            if let gap = line.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                let name = String(line[..<gap])
                var command = line[gap...].drop(while: { $0 == " " || $0 == "\t" })
                while let last = command.last, last == " " || last == "\t" { command = command.dropLast() }
                result.append((name, command.isEmpty ? nil : String(command)))
            } else {
                result.append((String(line), nil))
            }
        }
        return result
    }
}
