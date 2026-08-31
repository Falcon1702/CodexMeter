// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatchLayoutPreview",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/UsageCore"),
        .package(path: "../../Packages/WatchUI"),
    ],
    targets: [
        .executableTarget(
            name: "WatchLayoutPreview",
            dependencies: ["UsageCore", "WatchUI"]
        ),
    ]
)
