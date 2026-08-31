// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UsageCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
    ]
)
