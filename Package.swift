// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "csshm",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: no macOS APIs, so it can be unit-tested and ported.
        .target(name: "CsshmCore"),
        // Launcher, master and slave roles, plus the Terminal.app backend.
        .executableTarget(name: "csshm", dependencies: ["CsshmCore"]),
        .testTarget(name: "CsshmCoreTests", dependencies: ["CsshmCore"]),
    ]
)
