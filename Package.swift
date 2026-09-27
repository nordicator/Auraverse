// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Auraverse",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Auraverse", path: "Sources/Auraverse", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
