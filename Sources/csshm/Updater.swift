// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CsshmCore

/// `csshm --update`: fetches the latest released binary and puts it where
/// the running one is.
enum Updater {
    static let releaseURL = "https://github.com/anarchy89/csshm/releases/latest/download/csshm"

    private static func runProgram(_ path: String, _ arguments: [String], capture: Bool = false) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        if capture { process.standardOutput = pipe }
        do {
            try process.run()
        } catch {
            return (127, "")
        }
        let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func run() -> Never {
        let installed = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if installed.contains("/Cellar/") || installed.contains("/homebrew/") {
            die("this copy was installed with Homebrew; update it with: brew upgrade csshm")
        }

        // CSSHM_UPDATE_URL is an aid for testing.
        let url = ProcessInfo.processInfo.environment["CSSHM_UPDATE_URL"] ?? releaseURL
        let download = (NSTemporaryDirectory() as NSString).appendingPathComponent("csshm-update-\(getpid())")
        defer { try? FileManager.default.removeItem(atPath: download) }

        print("Checking \(url)")
        guard runProgram("/usr/bin/curl", ["-fsSL", "-o", download, url]).status == 0 else {
            die("could not download the latest release")
        }
        chmod(download, 0o755)
        let reported = runProgram(download, ["--version"], capture: true)
        let words = reported.output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard reported.status == 0, words.count == 2, words[0] == "csshm" else {
            die("the downloaded file is not a working csshm")
        }
        let latest = String(words[1])
        guard Version.isNewer(latest, than: csshmVersion) else {
            print("csshm \(csshmVersion) is up to date (the latest release is \(latest)).")
            exit(0)
        }

        let folder = (installed as NSString).deletingLastPathComponent
        if access(folder, W_OK) == 0 {
            // Write beside the old file, then swap, so there is never half a binary.
            let staged = installed + ".new"
            do {
                try? FileManager.default.removeItem(atPath: staged)
                try FileManager.default.copyItem(atPath: download, toPath: staged)
                guard rename(staged, installed) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                try? FileManager.default.removeItem(atPath: staged)
                die("could not replace \(installed)")
            }
        } else {
            print("Replacing \(installed) needs your password.")
            guard runProgram("/usr/bin/sudo", ["/usr/bin/install", "-m", "755", download, installed]).status == 0 else {
                die("could not replace \(installed)")
            }
        }
        print("Updated csshm \(csshmVersion) to \(latest).")
        exit(0)
    }
}
