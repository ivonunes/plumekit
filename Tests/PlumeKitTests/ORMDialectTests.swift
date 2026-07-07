import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// Schema introspection + per-dialect column DDL (used by Model.createTable and
// the Migrator's baseline check). The versioned migrator is tested separately in
// ORMMigratorTests.

@Test func introspectReadsCurrentColumns() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await db.query(
        "CREATE TABLE widget(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, qty INTEGER)", [])
    let cols = try await introspectColumns(table: "widget", in: db)
    #expect(cols.count == 3)
    #expect(asciiEqual(cols[0].name, "id"))
    #expect(cols[0].isPrimaryKey)
    #expect(asciiEqual(cols[1].name, "name"))
    #expect(asciiEqual(cols[2].name, "qty"))

    // A non-existent table introspects to empty.
    #expect(try await introspectColumns(table: "nope", in: db).isEmpty)
}

@Test func dialectRendersPrimaryKeyPerBackend() {
    let pk = ColumnSchema(name: "id", type: .integer, isPrimaryKey: true)
    #expect(SQLiteDialect().columnDefinition(pk).contains("id INTEGER PRIMARY KEY AUTOINCREMENT"))
    #expect(PostgresDialect().columnDefinition(pk).contains("id BIGSERIAL PRIMARY KEY"))   // 64-bit, matches BIGINT/Swift Int

    let qty = ColumnSchema(name: "qty", type: .integer)
    #expect(SQLiteDialect().columnDefinition(qty) == "qty INTEGER")
    #expect(PostgresDialect().columnDefinition(qty) == "qty BIGINT")
}
