// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Plume", targets: ["Plume"]),
        .executable(name: "plume", targets: ["PlumeCLI"])
    ],
    targets: [
        .target(name: "Plume"),
        .executableTarget(name: "PlumeCLI", dependencies: ["Plume"]),
        .testTarget(name: "PlumeTests", dependencies: ["Plume"])
    ]
)
