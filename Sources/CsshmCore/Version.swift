// SPDX-License-Identifier: GPL-3.0-or-later

public enum Version {
    /// True when version `candidate` (such as `0.2.0`) is later than `current`.
    /// Missing parts count as zero, so `1.2` equals `1.2.0`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
