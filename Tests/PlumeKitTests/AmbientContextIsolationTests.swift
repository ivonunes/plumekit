import Testing
@testable import PlumeCore
import PlumeServer

// Regression coverage for task-local ambient context isolation: two apps booted in
// one process (the shape of parallel Swift Testing suites, each with its own
// TestApp) must never see each other's ambient database. Before `RequestContext`
// became task-local on native, `Application.handle` stomped a process-wide global,
// so interleaved dispatch produced cross-suite flakes.

private func markerApp() -> Application {
    let app = Application()
    app.get("/marker") { _ in
        // Read through the AMBIENT database (`Database.current`), not the request's
        // explicit handle — that's the path that used to cross-talk.
        let result = try await Database.current.query("SELECT v FROM marker")
        guard case .text(let value) = result.rows[0][0] else {
            return .text("not-text", status: 500)
        }
        return .text(value)
    }
    return app
}

private func bootMarkerApp(value: String) async throws -> TestHTTPClient {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE marker(v TEXT)")
    _ = try await db.query("INSERT INTO marker(v) VALUES(?)", [.text(value)])
    return TestHTTPClient(markerApp(), context: Context(database: db))
}

@Test func concurrentAppsKeepTheirOwnAmbientDatabase() async throws {
    let alpha = try await bootMarkerApp(value: "alpha")
    let beta = try await bootMarkerApp(value: "beta")

    // Interleave many concurrent requests against both apps. Every response must
    // come from the app's own database — a single crossed value is the regression.
    await withTaskGroup(of: (expected: String, got: String).self) { group in
        for i in 0..<100 {
            let client = i % 2 == 0 ? alpha : beta
            let expected = i % 2 == 0 ? "alpha" : "beta"
            group.addTask {
                let response = await client.get("/marker")
                return (expected, response.bodyText)
            }
        }
        for await (expected, got) in group {
            #expect(got == expected)
        }
    }
}

@Test func requestBindingDoesNotLeakIntoTheProcessGlobal() async throws {
    // Startup-style code assigns the process-global fallback…
    let outer = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await outer.query("CREATE TABLE marker(v TEXT)")
    _ = try await outer.query("INSERT INTO marker(v) VALUES('outer')")
    let previous = RequestContext.current
    RequestContext.current = Context(database: outer)
    defer { RequestContext.current = previous }

    // …a request binds its own context task-locally around dispatch…
    let client = try await bootMarkerApp(value: "request")
    let response = await client.get("/marker")
    #expect(response.bodyText == "request")

    // …and after dispatch the ambient database is the startup one again (the
    // request binding was scoped, not an assignment that lingers).
    let result = try await Database.current.query("SELECT v FROM marker")
    #expect(result.rows[0][0] == .text("outer"))
}
