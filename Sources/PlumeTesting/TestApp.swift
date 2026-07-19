@_exported import PlumeCore
@_exported import PlumeORM
import PlumeServer
import _Concurrency

// PlumeTesting — helpers for testing a PlumeKit app natively: a fresh, migrated
// in-memory database per test, model factories (from PlumeORM), response assertions,
// and an auth helper. `import PlumeTesting` (it re-exports PlumeCore + PlumeORM), then:
//
//     let app = try await TestApp.boot(buildApp, migrations: runMigrations)
//     let user = try await User.factory.create(in: app.database)
//     let response = await app.client.get("/")
//     #expect(response.hasStatus(200))

/// A booted app under test: a fresh `:memory:` SQLite database with migrations applied,
/// wired into a Context (in-memory KV/cache/storage), and a `TestHTTPClient`. Build a
/// new `TestApp` per test so state never leaks between them.
public struct TestApp {
    public let app: Application
    public let context: Context
    public let database: Database
    public let client: TestHTTPClient
    /// The CSRF token to include in form POSTs (`"_csrf=\(app.csrfToken)&…"`); matches
    /// the secret the harness binds, so forms pass `csrfProtection()`.
    public let csrfToken: String

    /// Boot a test app. Pass your `buildApp` and `runMigrations`; the harness creates a
    /// fresh in-memory database, applies the migrations, and binds everything into a
    /// `TestHTTPClient`. `secrets` adds named secrets/vars the app under test should
    /// see (the harness's own CSRF secret is always bound). `http` stubs the outbound
    /// HTTP binding, so handlers that call third parties can be tested hermetically;
    /// nil leaves the binding unbound, as before.
    public static func boot(
        _ build: () -> Application,
        migrations: (Database) async throws -> [String] = { _ in [] },
        secrets extraSecrets: [String: String] = [:],
        http: (@Sendable (FetchRequest) async throws -> FetchResponse)? = nil
    ) async throws -> TestApp {
        NativeDrivers.installNativeClock()
        let database = try NativeDrivers.sqlite(path: ":memory:")
        _ = try await migrations(database)
        let csrfSecret = "plumekit-test-csrf-secret"
        let context = Context(
            kv: memoryKV(),
            database: database,
            storage: NativeDrivers.memoryStorage(),
            cache: NativeDrivers.memoryCache(),
            http: http.map { HTTP(StubHTTPClient(handler: $0)) },
            secrets: Secrets(secret: { name in
                if name == "CSRF_SECRET" { return Array(csrfSecret.utf8) }
                return extraSecrets[name].map { Array($0.utf8) }
            }),
            log: { _ in }
        )
        let app = build()
        let client = TestHTTPClient(app, context: context)
        // A fixed CSRF visitor value, pre-seeded into the jar: `app.csrfToken` is
        // its matching signed token, so form POSTs pass the double-submit check.
        let csrfValue = "plumekit-test-csrf-visitor"
        client.jar.set(CSRF.cookieName, csrfValue)
        return TestApp(app: app, context: context, database: database,
                       client: client,
                       csrfToken: CSRF.token(value: csrfValue, secret: csrfSecret))
    }
}

extension TestApp {
    /// Form POST with the harness's CSRF token appended automatically, so a
    /// controller test is just the fields it cares about:
    ///
    ///     let response = await app.postForm("/posts", [("title", "Hello world")])
    public func postForm(_ target: String, _ fields: [(String, String)],
                         headers: Headers = Headers()) async -> Response {
        await client.postForm(target, fields: fields + [(CSRF.fieldName, csrfToken)],
                              headers: headers)
    }
}

/// The closure-backed outbound-HTTP stub behind TestApp's `http:` parameter.
private struct StubHTTPClient: HTTPClient {
    let handler: @Sendable (FetchRequest) async throws -> FetchResponse
    func get(_ url: String) async throws -> FetchResponse {
        try await handler(FetchRequest(url: url))
    }
    func request(_ request: FetchRequest) async throws -> FetchResponse {
        try await handler(request)
    }
}

/// An in-memory KV for tests (native only).
public func memoryKV() -> KV {
    let box = MemoryKVBox()
    return KV(get: { await box.get($0) }, put: { await box.put($0, $1) })
}

private actor MemoryKVBox {
    private var data: [String: [UInt8]] = [:]
    func get(_ key: String) -> [UInt8]? { data[key] }
    func put(_ key: String, _ value: [UInt8]) { data[key] = value }
}
