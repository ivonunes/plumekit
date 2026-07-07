// swift-tools-version:6.2
import PackageDescription
import CompilerPluginSupport  // for `.macro` targets (the @Model compiler plugin)

// PlumeKit — a native Swift web framework for the edge, with the Plume templating
// language built in.
//
// One portable core, many platform adapters; the templating engine (Plume /
// PlumeRuntime) is an independently-usable module the framework consumes — an
// external static-site generator can depend on PlumeRuntime (or the Plume compiler)
// alone, without pulling the web framework.
//
//   • Plume / PlumeRuntime — the templating language: compiler + Embedded-clean
//                            render runtime.
//   • PlumeCore            — the platform-agnostic framework core (routing,
//                            request/response, middleware, auth, API, sync, channels).
//                            Embedded-Swift-clean so it compiles to tiny WebAssembly.
//   • PlumeServer          — native macOS/Linux HTTP/1.1 adapter (`plumekit serve`).
//   • PlumeWorker          — Embedded-clean glue for the Wasm worker adapter.
//   • plumekit             — the CLI (`new`, `serve`, `build --target cloudflare`,
//                            `compile`).
//
// The framework core is NOT linked against Foundation and avoids existentials,
// reflection and metatypes so it stays valid under Embedded Swift. See
// support/embedded-check.sh.
let package = Package(
    name: "PlumeKit",
    // macOS 14: the CLI embeds the Plume compiler and the native server uses
    // SwiftNIO's structured-concurrency APIs. Native-only; wasm ignores platform.
    platforms: [.macOS(.v14)],
    products: [
        // Templating — the Plume language. Independently usable (e.g. by an SSG).
        .library(name: "Plume", targets: ["Plume"]),
        // The tiny, Embedded-Swift-clean runtime generated render functions write
        // into. Its own product so an Embedded-Wasm consumer can depend on *only*
        // this (never the Foundation-using Plume compiler).
        .library(name: "PlumeRuntime", targets: ["PlumeRuntime"]),

        // Framework — PlumeKit.
        .library(name: "PlumeCore", targets: ["PlumeCore"]),
        .library(name: "PlumeServer", targets: ["PlumeServer"]),
        .library(name: "PlumeWorker", targets: ["PlumeWorker"]),
        // Opt-in native Postgres driver — only apps selecting it depend on libpq.
        .library(name: "PlumePostgres", targets: ["PlumePostgres"]),
        // Opt-in native S3 object-storage driver — only apps selecting it depend on crypto.
        .library(name: "PlumeS3", targets: ["PlumeS3"]),
        // Opt-in AWS adapter set: SigV4 + S3/SQS/SSM/DynamoDB/SES + the Lambda runtime,
        // behind the existing capability protocols.
        .library(name: "PlumeAWS", targets: ["PlumeAWS"]),
        // The ORM: @Model macro + typed query builder. Embedded-clean; talks only to
        // the SQLDatabase protocol (works on D1 and native SQLite alike).
        .library(name: "PlumeORM", targets: ["PlumeORM"]),
        // Native test helpers: migrated in-memory DB, factories, response assertions.
        .library(name: "PlumeTesting", targets: ["PlumeTesting"]),
        // The single framework CLI (build/serve/migrate/console + `compile`).
        .executable(name: "plumekit", targets: ["PlumeKitCLI"]),
        // Build-tool plugin: regenerates the composition root + typed Bindings from
        // plumekit.toml on every `swift build`.
        .plugin(name: "PlumeKitCodegen", targets: ["PlumeKitCodegen"]),
    ],
    dependencies: [
        // SwiftNIO — the native reference HTTP transport for PlumeServer.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // swift-crypto — SHA256/HMAC for the S3/AWS drivers' SigV4 signing.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // swift-syntax — powers the @Model macro (host compiler plugin only; its
        // OUTPUT is plain Embedded-clean Swift). 603.x matches Swift 6.3.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    ],
    targets: [
        // ── Templating (the Plume language) ──────────────────────────────────
        .target(name: "PlumeRuntime"),
        .target(name: "Plume"),

        // ── Framework (PlumeKit) ─────────────────────────────────────────────
        // Portable core — must compile under regular Swift AND embedded-wasm.
        // Depends on PlumeRuntime for the ambient render context (e.g. the CSRF
        // token views read through `@csrf`).
        .target(name: "PlumeCore", dependencies: ["PlumeRuntime"]),

        // System SQLite — the native SQL adapter links libsqlite3.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // Native HTTP adapter (SwiftNIO) + native binding adapters. Native-only.
        .target(name: "PlumeServer", dependencies: [
            "PlumeCore", "PlumeORM", "CSQLite",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),

        // Opt-in Postgres SQLDatabase driver (system libpq). Build with
        // PKG_CONFIG_PATH including libpq's pkgconfig (keg-only on brew).
        .systemLibrary(name: "CPostgres", path: "Sources/CPostgres", pkgConfig: "libpq",
                       providers: [.brew(["libpq"])]),
        .target(name: "PlumePostgres", dependencies: ["PlumeCore", "CPostgres"]),

        // The AWS adapter set: a reusable SigV4 signer + SQS/SSM/DynamoDB/SES + the
        // Lambda runtime, behind the existing capability protocols. Native only.
        .target(name: "PlumeAWS", dependencies: [
            "PlumeCore", .product(name: "Crypto", package: "swift-crypto"),
        ]),

        // Opt-in S3-compatible object-storage driver (Storage; SigV4 via swift-crypto).
        .target(name: "PlumeS3", dependencies: [
            "PlumeCore", "PlumeAWS", .product(name: "Crypto", package: "swift-crypto"),
        ]),

        // The @Model macro implementation — a HOST compiler plugin (SwiftSyntax).
        // Never linked into the app/wasm; only its emitted code is (Embedded-clean).
        .macro(name: "PlumeMacros", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),

        // The ORM runtime (Embedded-clean): Model, TableSchema, Row codec, typed
        // query builder, relationships. Declares @Model (via PlumeMacros).
        .target(name: "PlumeORM", dependencies: ["PlumeCore", "PlumeMacros"]),

        // Native test helpers (TestApp harness, factories, response assertions).
        .target(name: "PlumeTesting", dependencies: ["PlumeCore", "PlumeORM", "PlumeServer"]),

        // Embedded→Wasm worker glue. Needs the Extern feature for the
        // `@_extern(wasm, …)` host imports (KV, logging, the async host bridge).
        .target(
            name: "PlumeWorker",
            dependencies: ["PlumeCore", "PlumeORM"],
            swiftSettings: [.enableExperimentalFeature("Extern")],
            // Link Swift's Unicode data tables so app code can use native `String` ops
            // (`==`, `hasPrefix`, `lowercased`, `split`, `Dictionary<String, _>`) in the
            // Wasm guest — otherwise they fail to LINK. `.linkedLibrary` (NOT unsafeFlags,
            // which SwiftPM forbids in a version-pinned dependency) resolves the archive
            // from the SDK's default lib path. It rides on PlumeWorker, which every Worker
            // links, so no app-side Package.swift change is needed; scoped to wasi so the
            // native `serve`/AWS builds (which don't link PlumeWorker anyway) are untouched.
            linkerSettings: [.linkedLibrary("swiftUnicodeDataTables", .when(platforms: [.wasi]))]
        ),

        // The single `plumekit` CLI. Orchestrates swift / wasm-opt / wrangler, and
        // embeds the Plume compiler so it compiles templates in-process.
        .executableTarget(
            name: "PlumeKitCLI",
            dependencies: ["Plume"],
            // Embeds docs/ + runtime/cloudflare/ into the binary at build time (so
            // search_docs and Cloudflare builds work without a checkout); the
            // DocsEmbedded/CloudflareRuntimeEmbedded files are generated, never committed.
            plugins: ["PlumeEmbed"]
        ),

        // Native Swift Testing — the framework suite.
        .testTarget(name: "PlumeKitTests",
                    dependencies: ["PlumeCore", "PlumeServer", "PlumeWorker", "PlumeORM", "PlumeAWS"]),

        // The templating suite.
        .testTarget(name: "PlumeTests", dependencies: ["Plume", "PlumeRuntime"]),

        // The codegen tool the plugin runs (pure TOML→Swift). Reads plumekit.toml.
        .executableTarget(name: "plumekit-codegen"),

        // The build-tool plugin (composition vs bindings by the PlumeServer dep).
        .plugin(name: "PlumeKitCodegen", capability: .buildTool(), dependencies: ["plumekit-codegen"]),

        // Build-tool plugin that embeds docs/ + runtime/cloudflare/ into the CLI at build
        // time (applied only to PlumeKitCLI).
        .plugin(name: "PlumeEmbed", capability: .buildTool(), dependencies: ["plumekit-codegen"]),
    ]
)
