// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeMenuBar",
            path: "Sources/ClaudeMenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
