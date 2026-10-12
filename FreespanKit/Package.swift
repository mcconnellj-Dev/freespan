// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreespanKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FreespanKit", targets: ["FreespanKit"]),
    ],
    targets: [
        .target(
            name: "FreespanKit",
            resources: [.process("Rules/Rules.json"), .process("Identify/KnownLocations.json")]
        ),
        .testTarget(
            name: "FreespanKitTests",
            dependencies: ["FreespanKit"]
        ),
    ]
)
