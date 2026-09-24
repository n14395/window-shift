// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowShift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WindowShift",
            path: "Sources/WindowShift",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
