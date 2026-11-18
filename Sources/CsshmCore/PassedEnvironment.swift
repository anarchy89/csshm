// SPDX-License-Identifier: GPL-3.0-or-later

/// Environment variables to hand to the command in each host window
/// (`--env`). A host window is a new Terminal window, so without this the
/// command there does not see what was exported in the launching shell.
public enum PassedEnvironment {
    /// Turns `--env` values into `NAME=VALUE` entries. `NAME` alone takes the
    /// value from `environment`, the launcher's own; `NAME=VALUE` sets it.
    /// A later entry for the same name replaces an earlier one.
    ///
    /// With `required`, a bare name that is not set is an error. Without it
    /// (names from the settings file) such a name is skipped.
    public static func resolve(_ items: [String], from environment: [String: String], required: Bool) throws -> [String] {
        var order: [String] = []
        var values: [String: String] = [:]
        for item in items {
            let name: String
            let value: String?
            if let equals = item.firstIndex(of: "=") {
                name = String(item[..<equals])
                value = String(item[item.index(after: equals)...])
            } else {
                name = item
                value = environment[item]
            }
            guard isName(name) else {
                throw ConfigError("--env: [\(printable(name))] is not a variable name. Use NAME or NAME=VALUE")
            }
            guard let value = value else {
                if required {
                    throw ConfigError("--env \(name): \(name) is not set in this shell. Export it first or give --env \(name)=VALUE")
                }
                continue
            }
            guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ConfigError("--env \(name): the value contains a NUL character")
            }
            if values[name] == nil { order.append(name) }
            values[name] = value
        }
        return order.map { "\($0)=\(values[$0]!)" }
    }

    /// Entries from the settings file first, then the command line's, which win.
    public static func merge(_ lower: [String], _ higher: [String]) -> [String] {
        let replaced = Set(higher.map(name(of:)))
        return lower.filter { !replaced.contains(name(of: $0)) } + higher
    }

    public static func name(of entry: String) -> String {
        String(entry.prefix { $0 != "=" })
    }

    /// Letters, digits and underscores, not starting with a digit.
    public static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        func letter(_ s: Unicode.Scalar) -> Bool { (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || s == "_" }
        return letter(first) && text.unicodeScalars.allSatisfy { letter($0) || ($0 >= "0" && $0 <= "9") }
    }

    private static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) ? "?" : $0 }))
    }
}
