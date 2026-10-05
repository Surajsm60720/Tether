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
    ],
    targets: [
        .target(name: "TetherCore"),
        .testTarget(
            name: "TetherCoreTests",
            dependencies: ["TetherCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
