// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacLidAwake",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LidGoCore", targets: ["LidGoCore"]),
    ],
    targets: [
        .target(
            name: "LidGoCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "LidGoCoreTests",
            dependencies: ["LidGoCore"],
            path: "tests/LidGoCoreTests"
        ),
    ]
)
