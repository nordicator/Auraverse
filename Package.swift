// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyricAura",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "LyricAura", path: "Sources/LyricAura", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
