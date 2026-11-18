// SPDX-License-Identifier: GPL-3.0-or-later

/// A command to run in each window in place of ssh, written once with
/// placeholders for the target: `docker exec -it {} sh`.
///
///     {}       the host name
///     {user}   the user given with the host or the --login user
///     {port}   the port given with the host
///
/// The template is split into words the way a shell would and the words are
/// run directly, with no shell in between. A placeholder may sit inside a
/// word (`pod/{}`) and stays one word whatever the host is called.
public struct CommandTemplate: Equatable, Codable, Sendable {
    public let words: [String]

    public init(parsing text: String) throws {
        let words: [String]
        do {
            words = try ShellWords.split(text)
        } catch {
            throw ConfigError("--command: \(error)")
        }
        guard let program = words.first, !program.isEmpty else {
            throw ConfigError("--command is empty")
        }
        guard words.contains(where: { $0.contains("{}") }) else {
            throw ConfigError("--command needs {} where the host name goes, for example: docker exec -it {} sh")
        }
        guard !program.contains("{") else {
            throw ConfigError("--command must start with the program to run, not a placeholder")
        }
        self.words = words
    }

    public var usesUser: Bool { words.contains { $0.contains("{user}") } }
    public var usesPort: Bool { words.contains { $0.contains("{port}") } }

    /// Checks that a host supplies everything the template asks for and
    /// nothing that only makes sense for ssh.
    public func check(_ host: HostSpec, login: String?) throws {
        if usesUser, (host.user ?? login ?? "").isEmpty {
            throw ConfigError("--command uses {user} but [\(host.original)] has no user; add one or use --login")
        }
        if usesPort, host.port == nil {
            throw ConfigError("--command uses {port} but [\(host.original)] has no port")
        }
        if host.key != nil {
            throw ConfigError("[\(host.original)] names a key file, which only applies to ssh, not to --command")
        }
        if host.command != nil {
            throw ConfigError("[\(host.original)] has its own command, which only applies to ssh, not to --command")
        }
    }

    /// The argument list for one host.
    public func command(for host: HostSpec, login: String?) -> [String] {
        let user = host.user ?? login ?? ""
        let port = host.port ?? ""
        return words.map { word in
            word.replacing("{user}", with: user).replacing("{port}", with: port).replacing("{}", with: host.host)
        }
    }
}

extension String {
    /// Replaces every occurrence of `target`, without needing Foundation.
    func replacing(_ target: String, with replacement: String) -> String {
        guard !target.isEmpty, count >= target.count else { return self }
        var out = ""
        var index = startIndex
        while index < endIndex {
            if self[index...].hasPrefix(target) {
                out += replacement
                index = self.index(index, offsetBy: target.count)
            } else {
                out.append(self[index])
                index = self.index(after: index)
            }
        }
        return out
    }
}
