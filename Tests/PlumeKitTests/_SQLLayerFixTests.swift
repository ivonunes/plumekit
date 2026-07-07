import Testing
@testable import PlumeORM
@testable import PlumeServer

@Test func rowCoercesDoubleCellToIntWithoutTrapping() {
    #expect(Row([.double(5.0)]).int(0) == 5)
    #expect(Row([.double(5.7)]).int(0) == 5)            // truncate toward zero
    #expect(Row([.double(5.0)]).intOptional(0) == 5)
    #expect(Row([.double(.nan)]).int(0) == 0)           // no trap on NaN/huge
    #expect(Row([.double(1e300)]).int(0) == 0)
    #expect(Row([.integer(42)]).int(0) == 42)
    #expect(Row([.null]).intOptional(0) == nil)
}

@Test func sqliteEmptyBlobAndNulTextRoundTrip() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB, s TEXT)", [])
    _ = try await db.query("INSERT INTO t (b, s) VALUES (?, ?)", [.blob([]), .text("a\u{0}b")])
    let row = Row(try await db.query("SELECT b, s FROM t", []).rows[0])
    #expect(row.isNull(0) == false)          // empty blob is NOT null
    #expect(row.bytes(0) == [])
    #expect(row.string(1) == "a\u{0}b")      // embedded NUL preserved (bind + read by length)
}

@Test func offsetWithoutLimitDoesNotErrorOnSQLite() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query("CREATE TABLE t (id INTEGER PRIMARY KEY)", [])
    for _ in 0..<5 { _ = try await db.query("INSERT INTO t DEFAULT VALUES", []) }
    // OFFSET without LIMIT would be a SQLite syntax error without the Int.max LIMIT.
    let rows = try await db.query("SELECT id FROM t LIMIT \(Int.max) OFFSET 2", []).rows
    #expect(rows.count == 3)
}
