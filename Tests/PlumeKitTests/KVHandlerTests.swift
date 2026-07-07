import Foundation
import Testing
@testable import PlumeCore
@testable import PlumeServer

// Proves an async handler can `await` a KV binding end to end, in-process,
// against the native KV implementation — the same handler code that runs on
// Workers against the JSPI bridge.

private func get(_ app: Application, _ path: String, _ context: Context) async -> Response {
    await app.handle(Request(method: .get, path: path, context: context))
}

@Test func asyncHandlerDoesKVRoundTrip() async {
    let app = Application()
    app.get("/count") { request in
        guard let kv = request.context.kv else { return .text("no kv", status: 503) }
        let current = (await kv.getString("counter")).flatMap { Int($0) } ?? 0
        let next = current + 1
        await kv.putString("counter", String(next))
        return .text("count=\(next)")
    }

    // Shared context => shared store across requests (native parity with Workers).
    let context = NativeKV.memoryContext()

    #expect(await get(app, "/count", context).bodyText == "count=1")
    #expect(await get(app, "/count", context).bodyText == "count=2")
    #expect(await get(app, "/count", context).bodyText == "count=3")
}

@Test func kvGetReturnsNilForMissingKey() async {
    let app = Application()
    app.get("/lookup") { request in
        guard let kv = request.context.kv else { return .text("no kv", status: 503) }
        if let value = await kv.getString("absent") { return .text(value) }
        return .text("missing", status: 404)
    }

    let response = await get(app, "/lookup", NativeKV.memoryContext())
    #expect(response.status == 404)
    #expect(response.bodyText == "missing")
}

@Test func kvPutThenGetReturnsStoredBytes() async {
    let app = Application()
    app.get("/store") { request in
        guard let kv = request.context.kv else { return .text("no kv", status: 503) }
        await kv.putString("k", "the-value")
        let back = await kv.getString("k") ?? "<nil>"
        return .text(back)
    }

    #expect(await get(app, "/store", NativeKV.memoryContext()).bodyText == "the-value")
}

@Suite struct StoreFilenameTests {
    @Test func distinctKeysNeverCollide() {
        // All three collapsed to the same filename under the old "map to _" scheme.
        let names = Set(["sess:a/b", "sess:a+b", "sess:a b", "sess:a=b"].map(safeStoreFilename))
        #expect(names.count == 4)
    }

    @Test func filenamesAreTraversalSafe() {
        // No path separators and never "."/".." (which would escape the store dir).
        for key in ["../etc/passwd", "..", ".", "a/b/c", "x\\y"] {
            let name = safeStoreFilename(key)
            #expect(!name.contains("/"))
            #expect(name != "." && name != "..")
        }
    }
}

// The session revocation denylist writes each entry with the token's own expiry, so
// it self-evicts instead of growing forever (KV now honors an absolute expiresAt).
@Test func kvHonorsAbsoluteExpiry() async {
    let kv = NativeKV.memoryContext().kv!
    await kv.put("past", [1], expiresAt: 1)                                    // epoch 1 = long past
    #expect(await kv.get("past") == nil)                                       // already expired
    await kv.put("future", [2], expiresAt: Int(Date().timeIntervalSince1970) + 3600)
    #expect(await kv.get("future") == [2])                                     // within lifetime
    await kv.put("forever", [3])                                               // no expiry
    #expect(await kv.get("forever") == [3])
}

@Test func revocationEntrySelfExpires() async {
    let store = KVSessionStore(NativeKV.memoryContext().kv!)
    await store.revoke("sess-old", until: 1)                                   // token already expired
    #expect(await store.isRevoked("sess-old") == false)                       // entry evicted, not lingering
    await store.revoke("sess-live", until: Int(Date().timeIntervalSince1970) + 3600)
    #expect(await store.isRevoked("sess-live") == true)                       // still within lifetime → blocked
}

// The D1 deploy dump must be re-runnable: a second `plumekit deploy` re-runs migrate
// against the live D1, so emitted DDL is IF NOT EXISTS (else "table already exists").
@Test func schemaDumpEmitsIdempotentDDL() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT)", [])
    _ = try await db.query("CREATE UNIQUE INDEX idx_things_name ON things (name)", [])
    let dump = try await dumpDatabaseSQL(in: db, mode: .schema)
    #expect(dump.contains("CREATE TABLE IF NOT EXISTS things"))
    #expect(dump.contains("CREATE UNIQUE INDEX IF NOT EXISTS idx_things_name"))
}
