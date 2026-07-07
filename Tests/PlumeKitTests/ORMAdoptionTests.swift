import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// Database-first adoption: conforming a model to a PRE-EXISTING, externally-created
// schema that does not follow PlumeKit's code-first conventions. Every naming/typing
// convention is overridable — table name, column names, nullability, TEXT ISO-8601
// timestamps (vs Int64 epoch), and foreign-key column names — so the same active-record
// machinery works against a schema PlumeKit did not generate.

private func bytesEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

// A table whose name the pluralizer can't produce, with renamed/snake_case columns, a
// NULLABLE integer column, and TEXT ISO-8601 timestamps.
@Model(table: "user_accounts")
final class AdoptedUser: Model {
    var id: Int
    @Column("display_name") var name: String
    @Column("active_label_id") var activeLabelId: Int?
    @Column("created_at") var createdAt: String?
    @Column("updated_at") var updatedAt: String?
}

// Foreign-key column names that aren't `<name>ID`, one NOT NULL and one NULLABLE.
@Model(table: "account_follows")
final class AdoptedFollow: Model {
    var id: Int
    @BelongsTo(foreignKey: "follower_id") var follower: AdoptedUser?
    @BelongsTo(foreignKey: "following_id", nullable: true) var following: AdoptedUser?
    @Column("created_at") var createdAt: String?
}

// Reference/seed data: rows whose primary keys are authored, not auto-assigned.
@Model(table: "catalog_items")
final class CatalogItem: Model {
    var id: Int
    var name: String
    var priority: Int
    @Column("created_at") var createdAt: String?
    @Column("updated_at") var updatedAt: String?
}

@Test func overriddenSchemaMatchesExternalTableExactly() {
    let s = AdoptedUser.schema
    #expect(bytesEqual(s.table, "user_accounts"))           // table override
    #expect(s.columns.count == 5)
    #expect(bytesEqual(s.columns[0].name, "id") && s.columns[0].isPrimaryKey)
    #expect(bytesEqual(s.columns[1].name, "display_name"))   // column-name override
    #expect(!s.columns[1].isNullable)                        // String → NOT NULL
    #expect(bytesEqual(s.columns[2].name, "active_label_id"))
    #expect(s.columns[2].isNullable)                         // Int? → NULLABLE
    #expect(bytesEqual(s.columns[3].name, "created_at"))     // renamed TEXT timestamp
    #expect(s.columns[3].isNullable)

    let f = AdoptedFollow.schema
    #expect(bytesEqual(f.columns[1].name, "follower_id"))    // FK override (NOT NULL)
    #expect(!f.columns[1].isNullable)
    #expect(bytesEqual(f.columns[2].name, "following_id"))   // FK override (NULLABLE)
    #expect(f.columns[2].isNullable)
}

// The ISO-8601 formatter must be byte-identical to JavaScript's `Date.toISOString()`
// so an auto-touched TEXT timestamp matches one written by another runtime.
@Test func isoFromEpochMillisMatchesJavaScriptToISOString() {
    #expect(bytesEqual(isoFromEpochMillis(0), "1970-01-01T00:00:00.000Z"))
    #expect(bytesEqual(isoFromEpochMillis(1000), "1970-01-01T00:00:01.000Z"))
    #expect(bytesEqual(isoFromEpochMillis(86_400_000), "1970-01-02T00:00:00.000Z"))
    #expect(bytesEqual(isoFromEpochMillis(1_700_000_000_000), "2023-11-14T22:13:20.000Z"))
    #expect(bytesEqual(isoFromEpochMillis(1_700_000_000_123), "2023-11-14T22:13:20.123Z"))
    // Leap day 2024-02-29.
    #expect(bytesEqual(isoFromEpochMillis(1_709_208_000_000), "2024-02-29T12:00:00.000Z"))
}

// Read + write against an EXTERNALLY-created table (the DDL is the pre-existing schema,
// NOT one PlumeKit generated). NULLs round-trip as nil (never a silent 0), and
// renamed/odd-cased columns and ISO timestamps persist and reload faithfully.
extension SerializedClockTests {
@Test func adoptExternalTableReadsAndWritesFaithfully() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    // Externally-authored schema (column order deliberately different from the model's).
    _ = try await db.query("""
        CREATE TABLE user_accounts (
          id INTEGER PRIMARY KEY,
          active_label_id INTEGER,
          created_at TEXT,
          updated_at TEXT,
          display_name TEXT NOT NULL
        )
        """, [])

    // Deterministic clock so auto-touched timestamps are exact.
    let saved = ORMClock.now
    ORMClock.now = { 1_700_000_000_000 }
    defer { ORMClock.now = saved }

    // INSERT with a NULL nullable column.
    let a = AdoptedUser(name: "Ada")                // activeLabelId defaults to nil
    #expect(a.activeLabelId == nil)
    try await a.save(in: db)
    #expect(a.id > 0)
    #expect(a.createdAt != nil && bytesEqual(a.createdAt!, "2023-11-14T22:13:20.000Z"))  // ISO auto-touch
    #expect(bytesEqual(a.updatedAt!, "2023-11-14T22:13:20.000Z"))

    // Verify at the SQL layer that the nullable column is a REAL NULL, not 0.
    let raw = try await db.query("SELECT active_label_id, display_name, created_at FROM user_accounts WHERE id = ?", [sqlInt(a.id)])
    #expect(raw.rows.count == 1)
    if case .null = raw.rows[0][0] {} else { Issue.record("active_label_id should be SQL NULL, not 0") }
    if case .text(let dn) = raw.rows[0][1] { #expect(bytesEqual(dn, "Ada")) } else { Issue.record("display_name") }

    // Read back through the model: NULL → nil.
    let found = try await AdoptedUser.find(a.id, in: db)
    #expect(found != nil)
    #expect(bytesEqual(found!.name, "Ada"))
    #expect(found!.activeLabelId == nil)
    #expect(bytesEqual(found!.createdAt!, "2023-11-14T22:13:20.000Z"))

    // INSERT with a non-NULL nullable column.
    let b = AdoptedUser(name: "Grace", activeLabelId: 7)
    try await b.save(in: db)
    let foundB = try await AdoptedUser.find(b.id, in: db)
    #expect(foundB!.activeLabelId == 7)

    // UPDATE: change one column; updated_at re-touches, created_at stays.
    ORMClock.now = { 1_700_000_002_500 }
    found!.activeLabelId = 99
    try await found!.save(in: db)
    let reloaded = try await AdoptedUser.find(a.id, in: db)
    #expect(reloaded!.activeLabelId == 99)
    #expect(bytesEqual(reloaded!.createdAt!, "2023-11-14T22:13:20.000Z"))          // unchanged
    #expect(bytesEqual(reloaded!.updatedAt!, "2023-11-14T22:13:22.500Z"))          // re-touched

    // Typed query using the SWIFT property name → renamed SQL column.
    let byName = try await AdoptedUser.where(AdoptedUser.name == "Grace").all(in: db)
    #expect(byName.count == 1 && byName[0].activeLabelId == 7)
}
}

// A model keyed by a TEXT primary key (no integer `id` column). The schema couldn't be
// expressed by an `id`-only ORM — proving the framework can adopt a non-integer PK.
@Model(table: "reset_tokens", primaryKey: "email")
final class ResetToken: Model {
    var email: String
    var token: String? = nil
    @Column("created_at") var createdAt: String? = nil
}

extension SerializedClockTests {
@Test func stringPrimaryKeyUpsertQueryDelete() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE reset_tokens (email TEXT PRIMARY KEY, created_at TEXT, token TEXT)", [])
    let saved = ORMClock.now; ORMClock.now = { 1_700_000_000_000 }; defer { ORMClock.now = saved }

    // The schema's PK is the TEXT `email` column; there is no integer id.
    #expect(bytesEqual(ResetToken.primaryKeyColumn, "email"))
    #expect(ResetToken.schema.columns.first(where: { $0.isPrimaryKey })?.name.utf8.elementsEqual("email".utf8) == true)

    // upsert writes the row at its TEXT key and auto-touches created_at.
    let t = ResetToken(email: "a@b.c", token: "tok-1")
    try await t.upsert(in: db)
    // (No `.id`: a String-PK model doesn't declare one — it's keyed by `email`, above.)
    #expect(t.createdAt != nil && bytesEqual(t.createdAt!, "2023-11-14T22:13:20.000Z"))
    let raw = try await db.query("SELECT email, token FROM reset_tokens", [])
    #expect(raw.rows.count == 1)
    if case .text(let e) = raw.rows[0][0] { #expect(bytesEqual(e, "a@b.c")) } else { Issue.record("email PK") }

    // Re-upsert the same email → ON CONFLICT(email) updates in place; still one row.
    try await ResetToken(email: "a@b.c", token: "tok-2").upsert(in: db)
    #expect(try await ResetToken.all().count(in: db) == 1)

    // Query + delete work off the string PK (delete is NOT a hardcoded integer id).
    let found = try await ResetToken.where(ResetToken.email == "a@b.c").first(in: db)
    #expect(found != nil && found!.token != nil && bytesEqual(found!.token!, "tok-2"))
    try await found!.delete(in: db)
    #expect(try await ResetToken.all().count(in: db) == 0)
}
}

// Adopt a pre-existing database: record a forward-only baseline with NO DDL, leaving the
// live tables and data untouched, so a later migrate is a forward-only no-op.

// Authored (non-auto) primary keys: `upsert` writes a row at a caller-chosen id and is
// idempotent — re-running updates in place rather than inserting a duplicate.
extension SerializedClockTests {
@Test func upsertWritesRowsAtCallerChosenPrimaryKey() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE catalog_items (id INTEGER PRIMARY KEY, name TEXT, priority INTEGER, created_at TEXT, updated_at TEXT)", [])
    let saved = ORMClock.now; ORMClock.now = { 1_700_000_000_000 }; defer { ORMClock.now = saved }

    let a = CatalogItem(name: "Standard", priority: 10); a.id = 5
    try await a.upsert(in: db)
    #expect(a.id == 5)
    let found = try await CatalogItem.find(5, in: db)
    #expect(found != nil && bytesEqual(found!.name, "Standard") && found!.priority == 10)
    #expect(bytesEqual(found!.createdAt!, "2023-11-14T22:13:20.000Z"))   // ISO auto-touch on insert

    // Re-upsert the same id with new data → updates in place; still exactly one row.
    let b = CatalogItem(name: "Standard+", priority: 12); b.id = 5
    try await b.upsert(in: db)
    let reloaded = try await CatalogItem.find(5, in: db)
    #expect(bytesEqual(reloaded!.name, "Standard+") && reloaded!.priority == 12)
    #expect(try await CatalogItem.all().count(in: db) == 1)
}
}

// Nullable vs non-nullable FK columns: a NOT NULL FK persists its id; an unset NULLABLE
// FK persists SQL NULL (not 0) and reloads as "no relation".
@Test func belongsToForeignKeyNullabilityRoundTrips() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("""
        CREATE TABLE account_follows (
          id INTEGER PRIMARY KEY,
          follower_id INTEGER NOT NULL,
          following_id INTEGER,
          created_at TEXT
        )
        """, [])
    _ = try await db.query("CREATE TABLE user_accounts (id INTEGER PRIMARY KEY, active_label_id INTEGER, created_at TEXT, updated_at TEXT, display_name TEXT NOT NULL)", [])

    let me = AdoptedUser(name: "A"); try await me.save(in: db)

    let f = AdoptedFollow(follower: me)   // follower set; following left unset → NULL
    try await f.save(in: db)

    let raw = try await db.query("SELECT follower_id, following_id FROM account_follows WHERE id = ?", [sqlInt(f.id)])
    if case .integer(let fid) = raw.rows[0][0] { #expect(fid == Int64(me.id)) } else { Issue.record("follower_id should be set") }
    if case .null = raw.rows[0][1] {} else { Issue.record("following_id should be SQL NULL, not 0") }

    let reloaded = try await AdoptedFollow.find(f.id, in: db)
    #expect(reloaded!.$follower.id == me.id)
    #expect(reloaded!.$following.id == 0)   // NULL → "no relation"
}
