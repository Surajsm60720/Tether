// swift-tools-version: 6.0
// No third-party dependencies. Add one only with a justification in this file.

import PackageDescription

let package = Package(
    name: "TetherCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TetherCore", targets: ["TetherCore"]),
        // Small process the user runs on a machine with a public address. No third-party code.
        .executable(name: "tether-relay", targets: ["TetherRelay"]),
    ],
    targets: [
        .target(name: "TetherCore"),
        .executableTarget(name: "TetherRelay", dependencies: ["TetherCore"]),
        .testTarget(
            name: "TetherCoreTests",
            dependencies: ["TetherCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
