// Embedded templates for `plumekit new`. (The Cloudflare runtime — worker.mjs and
// the wrangler config — is read from the framework's runtime/cloudflare/ at build
// time; see Commands.swift. That keeps a single source of truth for the glue.)
//
// Substitution tokens: __NAME__ (project name) and __PLUMEKIT_DEPENDENCY__.

import Foundation

/// Choices that shape a scaffolded project (from interactive `plumekit new`, or defaults).
struct ScaffoldOptions {
    var capabilities: Set<String> = ["kv", "secrets"]   // secrets: CSRF_SECRET signs form tokens
    var defaultTarget: String = "cloudflare"
    var nativeDatabaseDriver: String = "sqlite"
    var includeDockerfile: Bool = true
    var ciProvider: String? = nil
}

/// A random hex string (default 32 bytes → 64 hex chars) for generated secrets.
func randomHexSecret(_ bytes: Int = 32) -> String {
    var rng = SystemRandomNumberGenerator()
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for _ in 0..<bytes {
        let b = UInt8.random(in: .min ... .max, using: &rng)
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
}

enum Templates {
    /// Files written by `plumekit new`. Paths are relative to the project root.
    static func projectFiles(name: String, plumeKitDependency: String,
                             options: ScaffoldOptions = ScaffoldOptions()) -> [(path: String, contents: String)] {
        let packageSwift = #"""
// swift-tools-version:6.2
import PackageDescription

// A PlumeKit application: one library of routes (`App`) consumed by three thin entry
// points — `Server` (native, for `plumekit serve`), `Worker` (Embedded-Swift Wasm,
// for `plumekit build --target cloudflare`), and `Lambda` (AWS, for
// `plumekit build --target aws`). All call the same buildApp().
let package = Package(
    name: "__NAME__",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Server", targets: ["Server"]),
        .executable(name: "Worker", targets: ["Worker"]),
        .executable(name: "Lambda", targets: ["Lambda"]),
    ],
    dependencies: [
        // The PlumeKit framework (with the Plume templating language). The app
        // depends only on the Embedded-clean PlumeRuntime for rendering.
        __PLUMEKIT_DEPENDENCY__
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                .product(name: "PlumeCore", package: "PlumeKit"),
                .product(name: "PlumeORM", package: "PlumeKit"),
                .product(name: "PlumeRuntime", package: "PlumeKit"),
            ],
            // Generates the typed `Bindings` (capability gate) from plumekit.toml.
            plugins: [.plugin(name: "PlumeKitCodegen", package: "PlumeKit")]
        ),
        .executableTarget(
            name: "Server",
            dependencies: ["App", .product(name: "PlumeServer", package: "PlumeKit")__SERVER_DRIVER_DEPS__],
            // Generates the native `Composition` root from plumekit.toml.
            plugins: [.plugin(name: "PlumeKitCodegen", package: "PlumeKit")]
        ),
        // Reactor linker flags for the Wasm build are supplied by `plumekit build`.
        .executableTarget(
            name: "Worker",
            dependencies: ["App", .product(name: "PlumeWorker", package: "PlumeKit")]
        ),
        // The AWS Lambda front-end. `plumekit build --target aws` packages it as a
        // provided.al2 bootstrap. The AWS profile uses Postgres (RDS) and S3, so the
        // matching driver modules are wired below when those capabilities are enabled.
        .executableTarget(
            name: "Lambda",
            dependencies: ["App", .product(name: "PlumeAWS", package: "PlumeKit")__LAMBDA_DRIVER_DEPS__],
            plugins: [.plugin(name: "PlumeKitCodegen", package: "PlumeKit")]
        ),
        // Tests run natively. PlumeTesting gives each test a fresh, migrated in-memory
        // database, model factories, a TestHTTPClient, and response assertions.
        .testTarget(
            name: "AppTests",
            dependencies: ["App", .product(name: "PlumeTesting", package: "PlumeKit")]
        ),
    ]
)
"""#

        let appSwift = #"""
import PlumeCore
import PlumeRuntime

/// Build the application. Both the native server and the Wasm worker call this,
/// so the same async routes run in both runtimes — including KV (a native store
/// under `plumekit serve`, Workers KV on the edge) and the Plume-rendered view.
public func buildApp() -> Application {
    let app = Application()

    // App-level middleware. Logging via the platform seam (→ console.log on Workers,
    // stdout natively).
    app.use { request, next in
        let response = try await next(request)
        request.context.log("\(request.method.name) \(request.path) -> \(response.status)")
        return response
    }

    // Let HTML forms issue PUT/PATCH/DELETE via a hidden `_method` field (browsers only
    // POST): rewrites the method before routing, so `resources` edit/update/destroy work.
    // Runs before CSRF so the token is validated against the real (overridden) method.
    app.use(methodOverride())

    // CSRF protection for web form POSTs. JSON and bearer-token requests are exempt
    // automatically. Signed with the CSRF_SECRET secret (generated into .env). Views
    // include the token with `@csrf`; read it in a handler via `request.csrfToken()`.
    app.use(csrfProtection())

    // Localization: resolves the request's language (see plumekit.toml [i18n] and any
    // Translations/*.json files) so handlers and views can call `t("key")`. A no-op
    // until you add translations.
    app.use(localization(plumeKitTranslations))

    registerRoutes(app)
    return app
}

// buildJobs() and buildSchedule() are GENERATED: every `Job` type under Sources/App/Jobs/
// is auto-registered (drop a file in — no manual registration), and the schedule you
// declare in Schedules.swift is wired in. Scaffold a job with `./plumekit generate job Foo`.
"""#

        let schedulesSwift = #"""
import PlumeCore

// Scheduled tasks, declared in one place (like Routes). `buildSchedule()` is generated
// from this. The schedule's tick is delivered as a job; times are UTC. The same code
// runs on every target — only the ticker differs (native timer / Cloudflare Cron Trigger
// / EventBridge rule).
func registerSchedules(_ schedule: inout Schedule) {
    // schedule.task("prune-sessions", every: .hourly()) { context in
    //     _ = try await context.database?.query("DELETE FROM sessions WHERE expires_at < ?", [now])
    // }
    // For durable work, enqueue a discovered Job instead of running inline:
    // schedule.task("daily-digest", every: .daily(hour: 6)) { context in
    //     try await SendDigest().enqueue(on: context.queue)
    // }
}
"""#

        let jobExampleSwift = #"""
import PlumeCore

// An example background job. ANY type conforming to `Job` under Sources/App/Jobs/ (any
// depth) is discovered and registered automatically — no manual wiring. `perform` runs
// in the consumer (native drainer / Cloudflare queue consumer) with a Context, so it
// reaches bindings like KV/DB/storage just like a handler. Enqueue with
// `try await ExampleJob(note: "hi").enqueue(on: queue)`.
struct ExampleJob: Job {
    static let name = "example"
    let note: String

    init(note: String) { self.note = note }
    init(payload: [UInt8]) { self.note = decodeUTF8(payload) }
    func payload() -> [UInt8] { encodeUTF8(note) }

    func perform(_ context: Context) async throws {
        context.log("example job ran: \(note)")
    }
}
"""#

        let databaseSwift = #"""
import PlumeCore
import PlumeORM

// Migrations and seeders are discovered automatically from Sources/App/Database/
// Migrations/ and Seeders/, in filename order. Scaffold one with
// `./plumekit generate migration CreatePosts` (or `generate seeder Posts`); it drops
// a file in that runs on the next `plumekit migrate` (or `plumekit seed`).

public func runMigrations(in db: Database) async throws -> [String] {
    try await Migrator(plumeKitMigrations).migrate(in: db)
}

// Ledger-aware pending-migration SQL for `plumekit migrate --local|--remote`: given the
// versions already in the target D1's `schema_migrations`, the exact up() SQL to run
// (only the pending migrations, plus their ledger inserts) — the wasm worker can't run
// migrations, so the native Server computes this and wrangler loads it. Native-only
// (matches Migrator.pendingMigrationSQL); excluded from the embedded Worker build.
#if !hasFeature(Embedded)
public func pendingMigrations(appliedVersions: [String], now: Int64)
        async throws -> (sql: String, pending: [String]) {
    let plan = try await Migrator(plumeKitMigrations).pendingMigrationSQL(
        appliedVersions: appliedVersions, dialect: .sqlite, now: now)
    return (plan.sql, plan.pending)
}
#endif

// `plumekit seed` runs every seeder; `plumekit seed <name>` runs just one.
public func runSeed(in db: Database, only name: String? = nil) async throws {
    try await runSeeders(plumeKitSeeders, only: name, in: db)
}
"""#

        let routesSwift = #"""
import PlumeCore
import PlumeRuntime

// The app's routes. Group related routes and mount controllers here — e.g.
// `app.resources("posts", PostController())`, or scope middleware with
// `app.group("/admin", middleware: [...]) { admin in ... }`.
func registerRoutes(_ app: Application) {
    // The front door: the welcome page, a Plume-rendered view. Views live in
    // Views/*.plume — a shared `Layout` and a `HomePage` that uses it — compiled to
    // render functions by `plumekit`. Replace HomePage with your own first page.
    app.get("/") { _ in
        .view(homePage())
    }

    app.get("/hello/:name") { request in
        let name = request.parameters["name"] ?? "world"
        return .text("Hello, \(name)!")
    }

    // KV-backed visit counter — identical code native and on Workers. `KV.current` is the
    // request's KV binding (available because plumekit.toml declares `kv = true`); ORM
    // and every capability follow the same pattern (`Post.all()`, `Cache.current`, …).
    app.get("/count") { _ in
        let kv = KV.current
        let current = (await kv.getString("counter")).flatMap { Int($0) } ?? 0
        let next = current + 1
        await kv.putString("counter", String(next))
        return .text("count=\(next)")
    }
}
"""#

        let plumeViewSwift = #"""
import PlumeCore
import PlumeRuntime

// App-level sugar: turn a rendered Plume `HTML` buffer into a PlumeKit `Response`.
// This is the response boundary, so it also finalizes the page: if any rendered
// component declared `@style` / `@script` / `@state` / `@navigation`, the compiled
// asset bundle's tags are spliced into the document's `<head>` here (fragments
// without a `<head>` pass through untouched — the receiving page has the bundle).
extension Response {
    static func view(_ html: HTML, status: Int = 200) -> Response {
        var page = html
        page.injectRequiredAssets()
        return .html(bytes: page.bytes, status: status)
    }
}

// App-level sugar: send an email whose HTML body is a rendered Plume view. Write the
// email as a `.plume` component (e.g. `@component WelcomeEmail(name: String) { … }`),
// render it, and pass it here with a plain-text fallback for clients that don't show HTML:
//
//   try await Mailer.current.send(to: user.email, subject: "Welcome",
//                                 view: welcomeEmail(name: user.name),
//                                 text: "Welcome, \(user.name)!")
extension Mailer {
    func send(from: String = "no-reply@example.com", to: String, subject: String,
              view: HTML, text: String) async throws {
        try await send(EmailMessage(
            from: from, to: to, subject: subject,
            textBody: text, htmlBody: String(decoding: view.bytes, as: UTF8.self)))
    }
}
"""#

        // Views are split across files: a shared `Layout` (the page shell + a slot for
        // content) and a `HomePage` that fills it — good practice as an app grows.
        let layoutPlume = #"""
@component Layout(title: String) {<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{title}</title>
    @style {
      :root { color-scheme: light dark; --fg: #1a1a1a; --muted: #666; --bg: #fff; }
      @media (prefers-color-scheme: dark) { :root { --fg: #e8e8e8; --muted: #999; --bg: #141414; } }
      *, *::before, *::after { box-sizing: border-box; }
      body {
        margin: 0;
        font: 16px/1.6 system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
        color: var(--fg);
        background: var(--bg);
      }
      main { max-width: 42rem; margin: 0 auto; padding: 3rem 1.25rem; }
      h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 1rem; }
      a { color: #2563eb; }
      .flash {
        padding: 0.65rem 1rem;
        border-radius: 8px;
        background: color-mix(in srgb, #16a34a 12%, var(--bg));
        border: 1px solid color-mix(in srgb, #16a34a 35%, var(--bg));
        color: inherit;
      }
      .field-error { display: block; margin-top: 0.25rem; font-size: 0.875rem; color: #dc2626; }
    }
    @navigation(root: "body", viewTransitions: true, scroll: "top")
  </head>
  <body><main>@slot</main></body>
</html>}
"""#

        // The welcome page a fresh app serves at `/`. Its `@style` block compiles into
        // the content-hashed bundle (Public/app.<hash>.css) the Layout links — so a
        // new project demonstrates scoped-to-the-view styling out of the box. Replace
        // this page with your own; the logo loads from plumekit.dev, nothing is bundled.
        let homePagePlume = #"""
@component HomePage() {@Layout(title: "Welcome to PlumeKit") {
  @style {
    .welcome {
      position: fixed; inset: 0; overflow: auto;
      background: #0b1018; color: #e6ebf2; text-align: center;
      font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    }
    .welcome::before {
      content: ""; position: fixed; inset: -20% -10% auto;
      height: 75vh; pointer-events: none;
      background: radial-gradient(60% 60% at 50% 30%, rgba(59, 130, 246, 0.16), rgba(167, 139, 250, 0.07) 55%, transparent 75%);
    }
    .welcome-inner { position: relative; max-width: 36rem; margin: 0 auto; padding: 5.5rem 1.5rem 4rem; }
    .welcome-logo { width: 76px; height: 76px; border-radius: 19px; box-shadow: 0 8px 32px rgba(37, 99, 235, 0.35); }
    .welcome-eyebrow { margin: 1.75rem 0 0.75rem; font-size: 0.75rem; font-weight: 700; letter-spacing: 0.14em; color: #60a5fa; }
    .welcome h1 { margin: 0 0 0.75rem; font-size: 2.6rem; line-height: 1.15; font-weight: 800; color: #fff; }
    .welcome h1 .grad {
      background: linear-gradient(90deg, #60a5fa, #a78bfa);
      -webkit-background-clip: text; background-clip: text; color: transparent;
    }
    .welcome-lede { color: #8b95a7; max-width: 28rem; margin: 0 auto 2.25rem; }
    .welcome-lede code { color: #c7d0dd; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
    .welcome-actions { display: flex; gap: 0.75rem; justify-content: center; margin-bottom: 3.25rem; }
    .welcome-btn { display: inline-block; padding: 0.65rem 1.3rem; border-radius: 10px; text-decoration: none; font-weight: 600; font-size: 0.95rem; }
    .welcome-btn-blue { background: #2563eb; color: #fff; box-shadow: 0 4px 18px rgba(37, 99, 235, 0.35); }
    .welcome-btn-line { border: 1px solid #2a3548; color: #e6ebf2; }
    .welcome-next {
      text-align: left; margin: 0; padding: 1.1rem 1.3rem; list-style: none;
      background: #111827; border: 1px solid #1f2937; border-radius: 12px;
      color: #8b95a7; font-size: 0.92rem;
    }
    .welcome-next li { margin: 0.55rem 0; }
    .welcome-next code { color: #e6ebf2; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
  }
  <div class="welcome">
    <div class="welcome-inner">
      <img class="welcome-logo" src="https://plumekit.dev/assets/plumekit.png" alt="PlumeKit">
      <p class="welcome-eyebrow">PLUMEKIT</p>
      <h1>You’re <span class="grad">up and running</span>.</h1>
      <p class="welcome-lede">This page is <code>Views/HomePage.plume</code>, rendered by
      your <code>/</code> route. Replace it with your own.</p>
      <div class="welcome-actions">
        <a class="welcome-btn welcome-btn-blue" href="https://plumekit.dev/docs/">Documentation</a>
        <a class="welcome-btn welcome-btn-line" href="https://plumekit.dev/docs/start/tutorial/">Build your first app</a>
      </div>
      <ul class="welcome-next">
        <li><code>./plumekit dev</code>: serve locally, restart on every change</li>
        <li><code>./plumekit generate resource Post title:string</code>: a working CRUD resource</li>
        <li><code>./plumekit deploy</code>: put the app live on your default target</li>
      </ul>
    </div>
  </div>
}}
"""#

        let serverMain = #"""
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import App
import PlumeCore
import PlumeServer

// Native entry point for `plumekit serve` (and `plumekit console` via --console).
// The request Context is built by the GENERATED composition root (from
// plumekit.toml) — swap a driver there to relink the adapter set, no change here.
var host = "127.0.0.1"
var port: UInt16 = 8080
var stateDir = ".plumekit"
var consoleMode = false
var migrateMode = false
var seedMode = false
var seedOnly: String?
var dumpMode = false
var dumpArg = "all"
var dumpExtra: String?

let arguments = CommandLine.arguments

// `--routes`: print the app's registered routes and exit (bindings not needed).
if arguments.contains("--routes") {
    for route in buildApp().routeList { print("\(route.method)\t\(route.path)") }
    exit(0)
}

var i = 1
while i < arguments.count {
    switch arguments[i] {
    case "--port":
        if i + 1 < arguments.count, let p = UInt16(arguments[i + 1]) { port = p; i += 1 }
    case "--host":
        if i + 1 < arguments.count { host = arguments[i + 1]; i += 1 }
    case "--state-dir":
        if i + 1 < arguments.count { stateDir = arguments[i + 1]; i += 1 }
    case "--console":
        consoleMode = true
    case "--migrate":
        migrateMode = true
    case "--seed":
        seedMode = true
        if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") { seedOnly = arguments[i + 1]; i += 1 }
    case "--dump-sql":
        dumpMode = true
        if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") { dumpArg = arguments[i + 1]; i += 1 }
        // Optional second positional: `--dump-sql seed <name>` seeds one seeder;
        // `--dump-sql pending <file>` reads the applied-versions file.
        if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") { dumpExtra = arguments[i + 1]; i += 1 }
    default:
        break
    }
    i += 1
}

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

// `plumekit migrate/seed --local|--remote` invoke this to obtain the SQL to load
// into a Cloudflare D1 (which the wasm worker can't migrate itself). Prints to
// stdout only; runs before the context so nothing else touches stdout.
if dumpMode {
    do {
        // `--dump-sql pending <file>`: ledger-aware migrate for a push-based D1. The
        // file holds the versions already in the target's ledger (newline-separated,
        // written by the CLI; missing/empty → nothing applied). Emit ONLY the pending
        // migrations' real up() SQL — never the additive-only full-schema dump.
        if dumpArg == "pending" {
            var appliedVersions: [String] = []
            if let file = dumpExtra, let contents = try? String(contentsOfFile: file, encoding: .utf8) {
                for line in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let v = line.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { appliedVersions.append(v) }
                }
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let plan = try await pendingMigrations(appliedVersions: appliedVersions, now: now)
            // Machine-readable header (a valid SQL comment; wrangler ignores it) so the
            // CLI can report the versions and skip wrangler when nothing is pending.
            print("-- plumekit-pending: " + plan.pending.joined(separator: ","))
            print(plan.sql, terminator: "")
            exit(0)
        }

        let mode: SQLDumpMode = dumpArg == "schema" ? .schema : (dumpArg == "seed" ? .seed : .all)
        let db = try NativeDrivers.sqlite(path: ":memory:")
        RequestContext.current = Context(database: db)   // ambient db for seeders during the dump
        _ = try await runMigrations(in: db)
        if mode != .schema { try await runSeed(in: db, only: dumpExtra) }
        print(try await dumpDatabaseSQL(in: db, mode: mode), terminator: "")
    } catch {
        FileHandle.standardError.write(Data("plumekit dump-sql: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}

let context: Context
do {
    context = try Composition.nativeContext(stateDirectory: stateDir)
} catch {
    print("plumekit: failed to build native context: \(error)")
    exit(1)
}
// Bind the context as ambient so migrations, seeders, and the console can use
// `Post.save()`, `KV.current`, `Cache.current`, … without threading it through.
RequestContext.current = context

if migrateMode {
    guard let database = context.database else {
        print("plumekit migrate: no database driver configured in plumekit.toml")
        exit(1)
    }
    do {
        let applied = try await runMigrations(in: database)
        print(applied.isEmpty ? "plumekit migrate: schema up to date" : "plumekit migrate: applied \(applied.count) change(s)")
        for version in applied { print("  + \(version)") }
    } catch {
        print("plumekit migrate: \(error)")
        exit(1)
    }
} else if seedMode {
    guard let database = context.database else {
        print("plumekit seed: no database driver configured in plumekit.toml")
        exit(1)
    }
    do {
        try await runSeed(in: database, only: seedOnly)
        print("plumekit seed: done")
    } catch {
        print("plumekit seed: \(error)")
        exit(1)
    }
} else if consoleMode {
    await PlumeServer.console(buildApp(), context: context)
} else {
    do {
        try await PlumeServer.run(buildApp(), host: host, port: port, context: context,
                                  jobs: buildJobs(), schedule: buildSchedule())
    } catch {
        print("plumekit serve: \(error)")
        exit(1)
    }
}
"""#

        let plumekitToml = manifest(options)

        let workerMain = #"""
// Wasm worker entry point for `plumekit build --target cloudflare`.
//
// The only place the C-ABI exports live; compiled solely for wasm (reactor model
// + JSPI), guarded on arch(wasm32). `plumekit_handle` takes a `ctx` id that routes
// host calls (KV, log) to the in-flight request's bindings; the JS glue wraps it
// with WebAssembly.promising so it can suspend across those calls.
//
// IMPORTANT (Embedded Swift gotchas): the app is cached in a `var = nil` global
// (reactor mode doesn't run lazy global initializers); `import _Concurrency` is
// required wherever async is used.
#if arch(wasm32)
import PlumeCore
import PlumeWorker
import App

nonisolated(unsafe) private var app: Application? = nil
nonisolated(unsafe) private var jobs: JobRegistry? = nil

@inline(__always)
private func sharedApp() -> Application {
    if let app { return app }
    let built = buildApp()
    app = built
    return built
}

@inline(__always)
private func sharedJobs() -> JobRegistry {
    if let jobs { return jobs }
    let built = buildJobs()
    jobs = built
    return built
}

@_expose(wasm, "plumekit_alloc")
@_cdecl("plumekit_alloc")
func plumekit_alloc(_ len: Int32) -> UnsafeMutableRawPointer? {
    plumekitAlloc(len)
}

@_expose(wasm, "plumekit_free")
@_cdecl("plumekit_free")
func plumekit_free(_ ptr: UnsafeMutableRawPointer?, _ len: Int32) {
    plumekitFree(ptr, len)
}

@_expose(wasm, "plumekit_handle")
@_cdecl("plumekit_handle")
func plumekit_handle(_ ctx: Int32, _ reqPtr: UnsafeMutableRawPointer?, _ reqLen: Int32) -> UnsafeMutableRawPointer? {
    plumekitHandle(sharedApp(), ctx, reqPtr, reqLen)
}

// Queue consumer entry: workerd's queue() handler calls this once per message.
@_expose(wasm, "plumekit_queue")
@_cdecl("plumekit_queue")
func plumekit_queue(_ ctx: Int32, _ msgPtr: UnsafeMutableRawPointer?, _ msgLen: Int32) {
    plumekitQueue(sharedJobs(), ctx, msgPtr, msgLen)
}
#endif
"""#

        let lambdaMain = #"""
import Foundation
import App
import PlumeCore
import PlumeAWS

// AWS Lambda entry — runs the SAME buildApp() as Server/Worker. The AWS composition
// root is generated from plumekit.toml's [targets.aws] profile (Composition.awsContext). For
// local testing, set AWS_ENDPOINT_URL=http://localhost:4566 (LocalStack).
let context: Context
do {
    context = try Composition.awsContext()
} catch {
    FileHandle.standardError.write(Data("plumekit(lambda): \(error)\n".utf8))
    exit(1)
}
try await LambdaAdapter.run(buildApp(), context: context)
"""#

        let readme = #"""
# __NAME__

A [PlumeKit](https://github.com/ivonunes/plumekit) app: one Swift codebase that
runs natively, on Cloudflare Workers, and on AWS Lambda.

## Develop natively

```
plumekit serve
#   GET /            -> the welcome page (Views/HomePage.plume)
#   GET /hello/ada   -> Hello, ada!
#   GET /count       -> count=N   (KV-backed, persisted under .plumekit/kv)
plumekit console       # interactive: type `GET /count`
```

## Deploy to Cloudflare Workers

```
plumekit build --target cloudflare       # compiles to Wasm, emits dist/cloudflare/
cd dist/cloudflare
# Create a KV namespace and put its id in wrangler.toml, then:
wrangler dev                            # or: wrangler deploy
```

## Deploy to AWS Lambda

```
plumekit build --target aws              # packages dist/aws/{bootstrap,function.zip}
# See dist/aws/README.md for env vars and a deploy snippet. Test locally against
# LocalStack by setting AWS_ENDPOINT_URL=http://localhost:4566.
```

## Project layout

```txt
Sources/App/
  App.swift          # buildApp(): app setup + middleware (buildJobs/buildSchedule are generated)
  Routes.swift       # registerRoutes(): your routes
  Schedules.swift    # registerSchedules(): your scheduled tasks
  Jobs/              # your Job types — auto-discovered & registered (any depth)
  Database/          # Migrations/, Seeders/, Factories/ (auto-discovered)
  Models/            # your @Model types (and domain structs)
  Controllers/       # controllers (plumekit generate controller / resource)
  Middleware/        # middleware (plumekit generate middleware)
  Support/           # helpers (e.g. PlumeView.swift)
Views/               # Plume templates (.plume): shared Layout at the root, a folder per resource
Public/              # static files served at / (images, fonts) + the compiled asset bundle
Tests/AppTests/      # tests; each gets a fresh, migrated database
```

Routes live in `Sources/App/Routes.swift`. Inside a handler, capabilities are
ambient: the ORM uses the request's database (`Post.all()`), and the rest are a
`.current` away (`KV.current`, `Cache.current`).
"""#

        // A self-bootstrapping wrapper: reads the PlumeKit version this project resolves
        // to (Package.resolved — the SwiftPM lock file) and runs the matching CLI
        // release, downloading + caching it from GitHub on first use. Commit it; then
        // contributors and CI need only `./plumekit …`, always at the version the app
        // builds against — no separate install.
        let plumekitWrapper = #"""
        #!/usr/bin/env bash
        # PlumeKit CLI wrapper. Runs the `plumekit` release matching this project's
        # resolved PlumeKit version (from Package.resolved), fetching it on first use.
        # Overrides: PLUMEKIT_BIN=/path/to/plumekit (a local build), PLUMEKIT_VERSION=x.y.z.
        set -euo pipefail

        root="$(cd "$(dirname "$0")" && pwd)"
        cache="${PLUMEKIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/plumekit}"

        # 1) An explicit binary wins (local framework development).
        if [ -n "${PLUMEKIT_BIN:-}" ]; then exec "$PLUMEKIT_BIN" "$@"; fi

        # 2) Resolve the version + source URL from the SwiftPM lock file (the one source
        #    of truth — the CLI is part of the same package the app depends on).
        lock="$root/Package.resolved"
        [ -f "$lock" ] || (cd "$root" && swift package resolve >/dev/null 2>&1) || true

        version="${PLUMEKIT_VERSION:-}"
        location=""
        if [ -f "$lock" ]; then
          block="$(grep -A6 -E '"identity"[[:space:]]*:[[:space:]]*"(plumekit|plume)"' "$lock" || true)"
          [ -n "$version" ] || version="$(printf '%s\n' "$block" | grep '"version"' | head -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
          location="$(printf '%s\n' "$block" | grep '"location"' | head -1 | sed -E 's/.*"location"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        fi

        if [ -z "$version" ]; then
          echo "plumekit: couldn't determine the PlumeKit version from Package.resolved." >&2
          echo "  Depending on PlumeKit by path/branch? Build the CLI and set PLUMEKIT_BIN," >&2
          echo "  or set PLUMEKIT_VERSION=x.y.z." >&2
          exit 1
        fi

        # 3) Use the cached binary, or download the matching release.
        bin="$cache/$version/plumekit"
        if [ ! -x "$bin" ]; then
          os="$(uname -s)"; arch="$(uname -m)"
          case "$os" in Darwin) os=macos;; Linux) os=linux;; *) echo "plumekit: unsupported OS $os" >&2; exit 1;; esac
          case "$arch" in arm64|aarch64) arch=arm64;; x86_64|amd64) arch=x86_64;; *) echo "plumekit: unsupported arch $arch" >&2; exit 1;; esac

          repo="${location%.git}"
          tag="v$version"
          tarball="plumekit-$tag-$os-$arch.tar.gz"
          tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
          echo "plumekit: fetching $tag ($os-$arch)…" >&2
          curl -fsSL "$repo/releases/download/$tag/$tarball" -o "$tmp/$tarball" \
            || { echo "plumekit: download failed ($repo/releases/download/$tag/$tarball)" >&2; exit 1; }
          if curl -fsSL "$repo/releases/download/$tag/plumekit-$tag-SHA256SUMS" -o "$tmp/SUMS" 2>/dev/null; then
            line="$(grep " $tarball$" "$tmp/SUMS" || true)"
            if [ -n "$line" ]; then
              ok=1
              if command -v sha256sum >/dev/null 2>&1; then
                (cd "$tmp" && printf '%s\n' "$line" | sha256sum -c - >/dev/null 2>&1) || ok=0
              elif command -v shasum >/dev/null 2>&1; then
                (cd "$tmp" && printf '%s\n' "$line" | shasum -a 256 -c - >/dev/null 2>&1) || ok=0
              fi
              [ "$ok" = 1 ] || { echo "plumekit: checksum verification failed" >&2; exit 1; }
            fi
          fi
          mkdir -p "$cache/$version"
          tar -xzf "$tmp/$tarball" -C "$cache/$version"
          [ -x "$bin" ] || { echo "plumekit: archive contained no plumekit binary" >&2; exit 1; }
        fi

        exec "$bin" "$@"
        """#

        // Container image for the native `Server` target — deploy the standalone
        // runtime anywhere that runs containers. (The Cloudflare/AWS targets deploy
        // via `plumekit build --target …` instead.)
        let dockerfile = """
        # Build + run the native PlumeKit server (the `Server` target / `plumekit serve`)
        # in a container — deploy it anywhere that runs containers (Fly.io, Render, ECS,
        # a VPS, k8s…). The Cloudflare (Worker) and AWS (Lambda) targets deploy
        # differently; see the README / docs.

        # ── build ────────────────────────────────────────────────────────────────
        FROM swift:6.3 AS build
        WORKDIR /app
        COPY . .
        # Generated views + composition come from `plumekit new` / the build plugin. If
        # you changed Views/, recompile first (e.g. `./plumekit compile Views -o Sources/App/Generated`).
        RUN swift build -c release --product Server --static-swift-stdlib

        # ── runtime ──────────────────────────────────────────────────────────────
        FROM swift:6.3-slim
        WORKDIR /app
        # Runtime libs for the enabled drivers (sqlite by default; add libpq5 for Postgres).
        RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 \\
            && rm -rf /var/lib/apt/lists/*
        COPY --from=build /app/.build/release/Server /app/Server
        EXPOSE 8080
        # Bind 0.0.0.0 so the server is reachable from outside the container.
        CMD ["/app/Server", "--host", "0.0.0.0", "--port", "8080"]
        """

        let dockerignore = """
        .build/
        .swiftpm/
        dist/
        .plumekit/
        .git/
        .wrangler/
        node_modules/
        """

        let gitignore = """
        .build/
        .swiftpm/
        dist/
        .plumekit/
        .wrangler/
        node_modules/
        .DS_Store
        .env
        .dev.vars
        # Generated Plume asset bundle (rebuilt by plumekit); your own files in Public/ stay tracked.
        Public/app.*
        """

        // Local signing secrets, freshly generated so protection works out of the box.
        // `.env` is read by the native server; `.dev.vars` by `wrangler dev`. Both are
        // gitignored. In production, set each key as a real secret (never commit them):
        //   wrangler secret put CSRF_SECRET | CHANNEL_SIGNING_KEY | AUTH_SECRET
        let csrfSecret = randomHexSecret()
        let channelSecret = randomHexSecret()
        let authSecret = randomHexSecret()
        let secretsBody = """
        CSRF_SECRET=\(csrfSecret)
        CHANNEL_SIGNING_KEY=\(channelSecret)
        AUTH_SECRET=\(authSecret)
        """
        let dotEnv = "# Local signing secrets (gitignored). Set real ones in production.\n" + secretsBody + "\n"
        let devVars = "# Local signing secrets for `wrangler dev` (gitignored). Use\n"
            + "# `wrangler secret put NAME` for deployed environments.\n" + secretsBody + "\n"

        let appTestsSwift = #"""
import Testing
@testable import App
import PlumeTesting

// Each test boots a fresh app: an in-memory SQLite database with your migrations
// applied, plus a TestHTTPClient. `import PlumeTesting` re-exports PlumeCore + PlumeORM.
// `@testable` lets tests reach your models (which are internal to the App module).
@Suite struct AppTests {
    @Test func homeRouteResponds() async throws {
        let app = try await TestApp.boot(buildApp, migrations: runMigrations)
        let response = await app.client.get("/")
        #expect(response.hasStatus(200))
        #expect(response.bodyContains("up and running"))   // the welcome page heading
    }

    // With `database = true` and a model + migration, each test gets a fresh migrated
    // database — create rows with a factory:
    //
    //   extension Post {
    //       static let factory = Factory { Post(title: "Example") }
    //   }
    //   @Test func listsPosts() async throws {
    //       let app = try await TestApp.boot(buildApp, migrations: runMigrations)
    //       _ = try await Post.factory.create(in: app.database)
    //       let response = await app.client.get("/posts")
    //       #expect(response.bodyContains("Example"))
    //   }
}
"""#

        // Wire the native SQL driver into the Server target only when the app uses
        // Postgres natively (SQLite is built into PlumeServer). The AWS profile always
        // uses Postgres for `database` and S3 for `storage`, so the Lambda target gets
        // those driver modules whenever those capabilities are enabled — otherwise the
        // generated composition would `import` a module the target doesn't depend on.
        func product(_ name: String) -> String {
            ", .product(name: \"\(name)\", package: \"PlumeKit\")"
        }
        let serverDriverDeps = options.nativeDatabaseDriver == "postgres" ? product("PlumePostgres") : ""
        var lambdaDriverDeps = ""
        if options.capabilities.contains("database") { lambdaDriverDeps += product("PlumePostgres") }
        if options.capabilities.contains("storage") { lambdaDriverDeps += product("PlumeS3") }

        func sub(_ s: String) -> String {
            s.replacingOccurrences(of: "__NAME__", with: name)
                .replacingOccurrences(of: "__PLUMEKIT_DEPENDENCY__", with: plumeKitDependency)
                .replacingOccurrences(of: "__SERVER_DRIVER_DEPS__", with: serverDriverDeps)
                .replacingOccurrences(of: "__LAMBDA_DRIVER_DEPS__", with: lambdaDriverDeps)
        }

        var files: [(path: String, contents: String)] = [
            ("Package.swift", sub(packageSwift)),
            ("plumekit.toml", plumekitToml),
            ("plumekit", plumekitWrapper),
            ("Sources/App/App.swift", sub(appSwift)),
            ("Sources/App/Routes.swift", routesSwift),
            ("Sources/App/Schedules.swift", schedulesSwift),
            ("Sources/App/Jobs/ExampleJob.swift", jobExampleSwift),
            ("Sources/App/Database/Database.swift", databaseSwift),
            ("Sources/App/Support/PlumeView.swift", sub(plumeViewSwift)),
            ("Sources/Server/main.swift", sub(serverMain)),
            ("Sources/Worker/main.swift", sub(workerMain)),
            ("Sources/Lambda/main.swift", sub(lambdaMain)),
            ("Views/Layout.plume", layoutPlume),
            ("Views/HomePage.plume", homePagePlume),
            ("Tests/AppTests/AppTests.swift", appTestsSwift),
            ("README.md", sub(readme)),
            (".gitignore", gitignore),
            (".env", dotEnv),
            (".dev.vars", devVars),
        ]
        if options.includeDockerfile {
            files.append(("Dockerfile", dockerfile))
            files.append((".dockerignore", dockerignore))
        }
        return files
    }

    /// The plumekit.toml manifest for the chosen scaffold options.
    static func manifest(_ options: ScaffoldOptions) -> String {
        let caps = ["kv", "database", "storage", "cache", "queue", "http", "secrets"]
        let capLines = caps.map { name in
            "\(name.padding(toLength: 8, withPad: " ", startingAt: 0)) = \(options.capabilities.contains(name))"
        }.joined(separator: "\n")
        return """
        # PlumeKit project manifest: capabilities, per-target driver selection, and build
        # config. Change a value + rebuild to relink a different adapter set with NO
        # app-code change. `plumekit` generates the composition root + typed Bindings.

        # Using a capability not declared here is a COMPILE error (no accessor). Flip one
        # to `true`, then pick its driver under the [targets.*] sections below.
        [capabilities]
        \(capLines)

        # `plumekit build`/`deploy` (no --target) use `default`; `--target all` covers
        # every entry in `targets`. `--target <name>` overrides both.
        [build]
        default = "\(options.defaultTarget)"
        targets = ["native", "cloudflare", "aws"]
        # out = "dist"   # bundle output directory

        # `plumekit deploy` runs these before shipping. Override per run with
        # --skip-migrations / --seed / --skip-seed.
        [deploy]
        migrate = true
        seed = false

        # The fallback language when the request matches none. Translations live in
        # Translations/<locale>.json (compiled in automatically).
        [i18n]
        default = "en"

        [targets.native]
        database = "\(options.nativeDatabaseDriver)"      # sqlite | postgres
        storage  = "filesystem"  # filesystem | memory | s3

        # Cloudflare adapters (D1 / R2 / KV) are configured in wrangler.toml.
        [targets.cloudflare]
        database = "d1"
        storage  = "r2"

        # AWS Lambda adapters. Set AWS_ENDPOINT_URL (e.g. http://localhost:4566) to point
        # every service at LocalStack for local testing. See docs/aws.md.
        [targets.aws]
        database = "postgres"
        storage  = "s3"
        cache    = "dynamodb"
        kv       = "dynamodb"
        queue    = "sqs"
        secrets  = "ssm"
        """
    }

    /// The README dropped into `dist/aws` by `plumekit build --target aws`.
    static func awsDeployReadme(name: String) -> String {
        """
        # \(name) — AWS Lambda bundle

        `bootstrap` is a `provided.al2` Lambda entrypoint; `function.zip` is deployable.

        ## Configuration (environment)

        The AWS composition reads config from the environment:

        | Var | Meaning |
        | --- | --- |
        | `AWS_REGION` | region (default us-east-1) |
        | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | credentials |
        | `AWS_ENDPOINT_URL` | override ALL service endpoints (http://localhost:4566 for LocalStack) |
        | `DATABASE_URL` | RDS Postgres connection string |
        | `S3_BUCKET` | object-storage bucket |
        | `KV_TABLE` / `CACHE_TABLE` | DynamoDB tables for KV / cache |
        | `SQS_URL` | queue URL |
        | `CHANNEL_TABLE` / `CHANNEL_MGMT_ENDPOINT` | channel state + postToConnection |

        ## Deploy

        ```sh
        aws lambda create-function --function-name \(name) \\
          --runtime provided.al2 --handler bootstrap --architectures arm64 \\
          --role <execution-role-arn> --zip-file fileb://function.zip
        ```

        Front it with an API Gateway HTTP API (proxy integration) for HTTP routes, and
        a WebSocket API for channels.

        ## Static files (Public/ → S3 + CloudFront)

        The build copied your `Public/` directory here as `./public` — your styles, images,
        and the content-hashed Plume bundle (`app.<hash>.js`). Lambda serves the dynamic
        routes; static files should be served by S3 behind CloudFront so they're cached at
        the edge (the native server and Cloudflare serve these same URLs directly).

        1. Upload the assets. The content hash makes them safe to cache forever:

           ```sh
           aws s3 sync ./public s3://<assets-bucket>/ \\
             --cache-control "public, max-age=31536000, immutable"
           ```

        2. Put CloudFront in front with two origins and route by path:
           - **S3** for the asset paths — `/app.*` and your files under
             `Public/` (add a cache behavior per pattern, or keep assets under a prefix).
           - **your API Gateway/Lambda** as the *default* behavior — everything else.

        Your app references assets by URL (`asset("app.js")` → `/app.<hash>.js`) exactly
        as it does natively and on Cloudflare; only *who* serves them changes per target.

        ## Test locally with LocalStack

        The framework ships `support/aws-localstack.sh`: it boots LocalStack, provisions
        the resources, and drives the same routes at `http://localhost:4566`.
        """
    }
}
