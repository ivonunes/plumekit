import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// The migrator: hand-authored SQL migrations, applied in
// order, tracked, reversible; plus the seeder runner.

private func widgetsUp() -> String {
    """
    -- create the widgets table with a real DEFAULT + NOT NULL
    CREATE TABLE widgets (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      qty INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX index_widgets_on_name ON widgets(name);
    """
}

private func migrations() -> [Migration] {
    [
        .sql(version: "0001_widgets", up: widgetsUp(),
             down: "DROP INDEX index_widgets_on_name; DROP TABLE widgets;"),
        .sql(version: "0002_add_color", up: "ALTER TABLE widgets ADD COLUMN color TEXT;",
             down: "ALTER TABLE widgets DROP COLUMN color;"),
    ]
}

@Test func migratorAppliesPendingInOrderAndIsIdempotent() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    let migrator = Migrator(migrations())

    let first = try await migrator.migrate(in: db)
    #expect(first == ["0001_widgets", "0002_add_color"])

    // The full-fidelity DDL actually ran: the DEFAULT and the new column exist.
    _ = try await db.query("INSERT INTO widgets (id, name) VALUES (1, 'a')", [])
    let row = try await db.query("SELECT qty, color FROM widgets WHERE id = 1", [])
    #expect(row.rows.first?[0] != nil)   // qty defaulted, color present → SELECT succeeds

    // Running again is a no-op (nothing pending).
    let second = try await migrator.migrate(in: db)
    #expect(second.isEmpty)

    let status = try await migrator.status(in: db)
    #expect(status.allSatisfy { $0.applied })
}

@Test func migratorRollsBackNewestFirst() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    let migrator = Migrator(migrations())
    _ = try await migrator.migrate(in: db)

    // Roll back one step → the latest migration's down() runs (color column drops).
    let reverted = try await migrator.rollback(in: db, steps: 1)
    #expect(reverted == ["0002_add_color"])
    // color is gone; widgets still exists.
    _ = try await db.query("SELECT name FROM widgets", [])
    let cols = try await introspectColumns(table: "widgets", in: db)
    #expect(cols.contains { asciiEqual($0.name, "name") })
    #expect(cols.contains { asciiEqual($0.name, "color") } == false)

    // Re-migrate re-applies just the rolled-back one.
    let reapplied = try await migrator.migrate(in: db)
    #expect(reapplied == ["0002_add_color"])
}

@Test func migratorBaselinesAnExistingSchemaWithoutRunning() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    // A database that already has the schema (built by a prior stack): create the
    // table by hand, THEN run the migrator with adoptExistingTable.
    _ = try await db.query("CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER NOT NULL DEFAULT 0)", [])
    let migrator = Migrator(migrations())

    // Nothing runs (it would fail — the table already exists) and every migration
    // is marked applied.
    let applied = try await migrator.migrate(in: db, adoptExistingTable: "widgets")
    #expect(applied.isEmpty)
    #expect(try await migrator.status(in: db).allSatisfy { $0.applied })

    // A fresh migration added later still applies forward.
    let extended = Migrator(migrations() + [
        .sql(version: "0003_add_note", up: "ALTER TABLE widgets ADD COLUMN note TEXT;")])
    let forward = try await extended.migrate(in: db, adoptExistingTable: "widgets")
    #expect(forward == ["0003_add_note"])
}

@Test func splitSQLStatementsHandlesCommentsAndQuotes() {
    let sql = """
    -- a leading comment
    CREATE TABLE t (a TEXT NOT NULL DEFAULT '[]');
    INSERT INTO t (a) VALUES ('x;y');   -- a semicolon inside a string
    """
    let statements = splitSQLStatements(sql)
    #expect(statements.count == 2)
    #expect(contains(statements[0], "CREATE TABLE t"))
    #expect(contains(statements[1], "'x;y'"))   // not split at the quoted ';'
}

private final class Counter: @unchecked Sendable { var n = 0; func next() -> Int { n += 1; return n } }

@Test func seedersRunInOrder() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    _ = try await Migrator(migrations()).migrate(in: db)
    let box = Counter()
    let seed = Seeder { db in
        _ = try await db.query("INSERT INTO widgets (id, name) VALUES (?, 'seed')", [sqlInt(box.next())])
    }
    try await runSeeders([seed, seed], in: db)
    let count = try await db.query("SELECT COUNT(*) FROM widgets", [])
    if case .integer(let n)? = count.rows.first?.first { #expect(n == 2) } else { Issue.record("no count") }
}

// Ledger-aware pending SQL for a push-based D1: emit ONLY the not-yet-applied
// migrations' real up() statements (+ ledger inserts), computed against a recording
// Database — never the additive-only full-schema dump.
private func schemaBuilderMigrations() -> [Migration] {
    [
        Migration(version: "0001_create_foo", up: { db in
            try await db.createTable("foo") { t in
                t.id()
                t.text("name")
            }
        }),
        Migration(version: "0002_add_bar", up: { db in
            try await db.alterTable("foo") { t in
                t.addColumn("bar", .text, nullable: true)
            }
        }),
    ]
}

@Test func pendingMigrationSQLEmitsOnlyTheNotYetAppliedMigrations() async throws {
    let migrator = Migrator(schemaBuilderMigrations())

    // v1 already applied → only v2's ALTER + its ledger INSERT; NOT v1's CREATE TABLE.
    let afterV1 = try await migrator.pendingMigrationSQL(
        appliedVersions: ["0001_create_foo"], dialect: .sqlite, now: 1000)
    #expect(afterV1.pending == ["0002_add_bar"])
    #expect(contains(afterV1.sql, "ALTER TABLE foo ADD COLUMN bar"))
    #expect(contains(afterV1.sql, "INSERT INTO schema_migrations"))
    #expect(contains(afterV1.sql, "0002_add_bar"))          // ledger insert names the version
    #expect(contains(afterV1.sql, "CREATE TABLE foo") == false)   // v1 applied → skipped
    // The ledger DDL is always present (idempotent CREATE), so a fresh D1 gets its table;
    // no explicit transaction framing (Cloudflare D1 rejects BEGIN/COMMIT in executed SQL).
    #expect(contains(afterV1.sql, "CREATE TABLE IF NOT EXISTS schema_migrations"))
    #expect(contains(afterV1.sql, "BEGIN TRANSACTION") == false)
    #expect(contains(afterV1.sql, "COMMIT") == false)

    // Nothing applied → BOTH migrations' statements + the ledger CREATE.
    let fresh = try await migrator.pendingMigrationSQL(
        appliedVersions: [], dialect: .sqlite, now: 1000)
    #expect(fresh.pending == ["0001_create_foo", "0002_add_bar"])
    #expect(contains(fresh.sql, "CREATE TABLE foo"))
    #expect(contains(fresh.sql, "ALTER TABLE foo ADD COLUMN bar"))
    #expect(contains(fresh.sql, "CREATE TABLE IF NOT EXISTS schema_migrations"))
    #expect(contains(fresh.sql, "BEGIN TRANSACTION") == false)

    // All applied → the ledger CREATE but NO migration INSERTs (pending empty).
    let done = try await migrator.pendingMigrationSQL(
        appliedVersions: ["0001_create_foo", "0002_add_bar"], dialect: .sqlite, now: 1000)
    #expect(done.pending.isEmpty)
    #expect(contains(done.sql, "CREATE TABLE IF NOT EXISTS schema_migrations"))
    #expect(contains(done.sql, "INSERT INTO schema_migrations") == false)
}

private func contains(_ haystack: String, _ needle: String) -> Bool {
    let h = Array(haystack.utf8)
    let n = Array(needle.utf8)
    if n.isEmpty || h.count < n.count { return false }
    for start in 0...(h.count - n.count) {
        var ok = true
        for j in 0..<n.count where h[start + j] != n[j] { ok = false; break }
        if ok { return true }
    }
    return false
}
