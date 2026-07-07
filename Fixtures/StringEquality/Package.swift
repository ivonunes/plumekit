// swift-tools-version:6.2
import PackageDescription

// A tiny executable that EXERCISES native Swift `String` operations (`==`, `!=`,
// `hasPrefix`, `hasSuffix`, `lowercased`, `split`, `Dictionary<String, _>`) and asserts
// their results at runtime. Built for Embedded-Wasm by support/embedded-check.sh to prove
// those operations LINK and RUN in the guest once Swift's Unicode data tables are linked
// in — and to fail loudly if a toolchain bump changes the required symbols.
//
// `.linkedLibrary` resolves libswiftUnicodeDataTables.a from the SDK's default lib path
// (the same mechanism PlumeWorker uses for real apps); scoped to wasi.
let package = Package(
    name: "StringEquality",
    targets: [
        .executableTarget(
            name: "StringEquality",
            linkerSettings: [.linkedLibrary("swiftUnicodeDataTables", .when(platforms: [.wasi]))]
        )
    ]
)
