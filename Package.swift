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
