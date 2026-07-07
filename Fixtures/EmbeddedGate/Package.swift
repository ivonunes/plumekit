// swift-tools-version:6.2
// A self-contained consumer of Plume's compiling back-end, mirroring how PlumeKit
// will depend on it: a `.plume` view is compiled to Swift (into Sources/Gate/
// Generated) and built against the Embedded-clean PlumeRuntime product only.
import PackageDescription

let package = Package(
    name: "EmbeddedGate",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "PlumeKit", path: "../..")],
    targets: [
        .executableTarget(
            name: "Gate",
            dependencies: [.product(name: "PlumeRuntime", package: "PlumeKit")]
        )
    ]
)
