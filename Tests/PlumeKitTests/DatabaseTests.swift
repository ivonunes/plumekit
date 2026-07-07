import Testing
@testable import PlumeCore
import PlumeServer

// Exercises the native SQLite adapter and the neutral Database handle. (Tests run
// natively, so String == here is fine — the Unicode-linking restriction is an
// Embedded constraint, not a native one.)

@Test func sqliteReturnsTypedRows() async throws {
    let db = try SQLiteDatabase(path: ":memory:")
    _ = try await db.query("CREATE TABLE post(id INTEGER PRIMARY KEY, title TEXT, score REAL)")
    _ = try await db.query("INSERT INTO post(title, score) VALUES(?, ?)", [.text("a & b"), .double(3.5)])
    _ = try await db.query("INSERT INTO post(title, score) VALUES(?, ?)", [.text("low"), .double(1.0)])

    let result = try await db.query("SELECT id, title, score FROM post WHERE score > ? ORDER BY id", [.double(2.0)])
    #expect(result.columns == ["id", "title", "score"])
    #expect(result.rows.count == 1)
    if case .integer(let id) = result.rows[0][0] { #expect(id == 1) } else { Issue.record("id not integer") }
    if case .text(let t) = result.rows[0][1] { #expect(t == "a & b") } else { Issue.record("title not text") }
    if case .double(let s) = result.rows[0][2] { #expect(s == 3.5) } else { Issue.record("score not double") }
}

@Test func databaseHandleWrapsAnyAdapter() async throws {
    // The Embedded-clean `Database` handle wraps a concrete adapter via `some`.
    let handle = Database(try SQLiteDatabase(path: ":memory:"))
    _ = try await handle.query("CREATE TABLE t(x INTEGER)")
    let write = try await handle.query("INSERT INTO t(x) VALUES(?)", [.integer(42)])
    #expect(write.rowsAffected == 1)
    let read = try await handle.query("SELECT x FROM t")
    if case .integer(let x) = read.rows[0][0] { #expect(x == 42) } else { Issue.record("not integer") }
}

@Test func nullAndBlobRoundTrip() async throws {
    let db = try SQLiteDatabase(path: ":memory:")
    _ = try await db.query("CREATE TABLE b(data BLOB, maybe TEXT)")
    _ = try await db.query("INSERT INTO b(data, maybe) VALUES(?, ?)", [.blob([0, 1, 2, 255]), .null])
    let r = try await db.query("SELECT data, maybe FROM b")
    if case .blob(let bytes) = r.rows[0][0] { #expect(bytes == [0, 1, 2, 255]) } else { Issue.record("not blob") }
    if case .null = r.rows[0][1] {} else { Issue.record("not null") }
}
