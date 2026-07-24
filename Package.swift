// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitorMirror",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MonitorMirrorCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MonitorMirror",
            dependencies: ["MonitorMirrorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MonitorMirrorCoreTests",
            dependencies: ["MonitorMirrorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
