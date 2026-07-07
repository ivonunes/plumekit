import PlumeCore
import PlumeORM
import _Concurrency

// A syncable resource (Note) + its sync endpoints, exercising all 8 sync
// primitives over the wire. The SAME app code on native, Cloudflare, and AWS.

@Model
final class Note: Model {
    var id: Int               // local primary key
    var uid: String = ""      // (1) stable, client-mintable global id
    var version: Int64 = 0    // (2) server-assigned monotonic change version
    var deleted: Bool = false // (3) tombstone
    var ownerID: String = ""  // (8) auth-bounded scope
    var body: String = ""
}

let noteSchemaVersion = 1

func noteRecord(_ note: Note) -> SyncRecord {
    SyncRecord(uid: note.uid, version: note.version, deleted: note.deleted, schema: noteSchemaVersion,
               data: note.deleted ? .object([]) : .object([("body", .string(note.body))]))
}

// SQL-backed SyncStore over the notes table — the persistence adapter the SyncEngine
// drives. Uses RAW bound SQL (like SQLCredentialStore): the typed query builder's
// String-column predicates pull Unicode normalization into the wasm guest (those
// tables don't link there), so byte-safe raw SQL is the embedded-clean path.
// Idempotency outcomes live in KV.
struct NoteSyncStore: SyncStore {
    let db: Database
    let kv: KV

    private func recordRow(_ row: [SQLValue]) -> SyncRecord {
        var uid = "", version: Int64 = 0, deleted = false, body = ""
        if case .text(let s) = row[0] { uid = s }
        if case .integer(let n) = row[1] { version = n }
        if case .integer(let d) = row[2] { deleted = d != 0 }
        if case .text(let b) = row[3] { body = b }
        return SyncRecord(uid: uid, version: version, deleted: deleted, schema: noteSchemaVersion,
                          data: deleted ? .object([]) : .object([("body", .string(body))]))
    }

    func recordByUID(_ uid: String) async throws -> SyncRecord? {
        let r = try await db.query("SELECT uid, version, deleted, body FROM notes WHERE uid = ?", [.text(uid)])
        guard let row = r.rows.first else { return nil }
        return recordRow(row)
    }
    func ownerOfUID(_ uid: String) async throws -> String? {
        let r = try await db.query("SELECT ownerID FROM notes WHERE uid = ?", [.text(uid)])
        guard let row = r.rows.first, case .text(let o) = row[0] else { return nil }
        return o
    }
    func nextVersion() async throws -> Int64 {
        let result = try await db.query("SELECT MAX(version) FROM notes", [])
        if let row = result.rows.first, case .integer(let n) = row[0] { return n + 1 }
        return 1
    }
    func upsert(uid: String, version: Int64, deleted: Bool, data: JSONValue, owner: String) async throws {
        let body = data["body"]?.stringValue ?? ""
        let exists = try await db.query("SELECT 1 FROM notes WHERE uid = ? LIMIT 1", [.text(uid)])
        let del: SQLValue = .integer(deleted ? 1 : 0)
        if exists.rows.isEmpty {
            _ = try await db.query(
                "INSERT INTO notes (uid, version, deleted, ownerID, body) VALUES (?, ?, ?, ?, ?)",
                [.text(uid), .integer(version), del, .text(owner), .text(body)])
        } else if deleted {
            _ = try await db.query("UPDATE notes SET version = ?, deleted = ? WHERE uid = ?",
                                   [.integer(version), del, .text(uid)])
        } else {
            _ = try await db.query("UPDATE notes SET version = ?, deleted = ?, body = ? WHERE uid = ?",
                                   [.integer(version), del, .text(body), .text(uid)])
        }
    }
    func changes(since: Int64, owner: String) async throws -> [SyncRecord] {
        let r = try await db.query(
            "SELECT uid, version, deleted, body FROM notes WHERE ownerID = ? AND version > ? ORDER BY version",
            [.text(owner), .integer(since)])
        return r.rows.map { recordRow($0) }
    }
    func appliedOutcome(_ key: String) async -> SyncRecord? {
        guard let bytes = await kv.get("plumekit:idem:notes:" + key) else { return nil }
        return SyncRecord.parse(parseJSON(bytes))
    }
    func markApplied(_ key: String, _ record: SyncRecord) async {
        await kv.put("plumekit:idem:notes:" + key, record.json().serialize())
    }
}

func registerSyncRoutes(_ app: Application) {
    // GET /api/v1/sync/notes?since=<cursor> → delta (changes + tombstones + new cursor),
    // scoped to the authenticated owner.
    app.get("/api/v1/sync/notes") { request in
        let db = request.bindings.database
        try await Note.createTable(in: db)
        guard let owner = request.currentUser else {
            return APIError(status: 401, code: "unauthorized", message: "authentication required").response()
        }
        let since = Int64(Int(request.queryParams["since"] ?? "") ?? 0)
        let engine = SyncEngine(schema: noteSchemaVersion, store: NoteSyncStore(db: db, kv: request.bindings.kv))
        let (changes, cursor) = try await engine.delta(since: since, owner: owner)
        return .json(deltaJSON(changes, cursor: cursor, schema: noteSchemaVersion))
    }

    // POST /api/v1/sync/notes — an idempotent, version-based mutation intent →
    // applied / deduped / conflict / schema-mismatch / unauthorized.
    app.post("/api/v1/sync/notes") { request in
        let db = request.bindings.database
        try await Note.createTable(in: db)
        guard let owner = request.currentUser else {
            return APIError(status: 401, code: "unauthorized", message: "authentication required").response()
        }
        guard let intent = MutationIntent.parse(request.json()) else {
            return APIError(status: 400, code: "bad_request", message: "malformed mutation intent").response()
        }
        let engine = SyncEngine(schema: noteSchemaVersion, store: NoteSyncStore(db: db, kv: request.bindings.kv))
        return try await engine.apply(intent, owner: owner).response()
    }
}
