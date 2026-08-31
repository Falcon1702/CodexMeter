// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatchUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "WatchUI", targets: ["WatchUI"]),
    ],
    dependencies: [
        .package(path: "../UsageCore"),
    ],
    targets: [
        .target(
            name: "WatchUI",
            dependencies: ["UsageCore"]
        ),
    ]
)
