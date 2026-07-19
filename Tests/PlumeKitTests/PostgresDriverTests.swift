import Testing
import Foundation
@testable import PlumeCore
import PlumeORM
@testable import PlumePostgres

// Live-server integration tests for the pooled Postgres driver. Gated on
// PLUMEKIT_TEST_POSTGRES_URL (e.g. "host=127.0.0.1 dbname=plumekit_driver_test")
// so environments without a server skip instead of failing.

private func postgresURL() -> String? {
    ProcessInfo.processInfo.environment["PLUMEKIT_TEST_POSTGRES_URL"]
}

@Suite(.serialized) struct PostgresDriverTests {
    @Test(.enabled(if: postgresURL() != nil))
    func crudRoundTripAndAffectedRows() async throws {
        let db = try PostgresDriver.connect(url: postgresURL()!)
        _ = try await db.query("DROP TABLE IF EXISTS pg_widgets", [])
        _ = try await db.query("CREATE TABLE pg_widgets (id BIGSERIAL PRIMARY KEY, name TEXT, qty BIGINT)", [])

        for i in 1...3 {
            _ = try await db.query("INSERT INTO pg_widgets (name, qty) VALUES (?, ?)",
                                   [.text("w\(i)"), .integer(Int64(i * 10))])
        }
        let rows = try await db.query("SELECT name, qty FROM pg_widgets ORDER BY id", [])
        #expect(rows.rows.count == 3)
        #expect(rows.rows[2] == [.text("w3"), .integer(30)])

        let updated = try await db.query("UPDATE pg_widgets SET qty = qty + 1 WHERE qty >= ?", [.integer(20)])
        #expect(updated.rowsAffected == 2)
        _ = try await db.query("DROP TABLE pg_widgets", [])
    }

    @Test(.enabled(if: postgresURL() != nil))
    func byteaTravelsInBinaryAndRoundTrips() async throws {
        let db = try PostgresDriver.connect(url: postgresURL()!)
        _ = try await db.query("DROP TABLE IF EXISTS pg_blobs", [])
        _ = try await db.query("CREATE TABLE pg_blobs (id BIGSERIAL PRIMARY KEY, data BYTEA)", [])

        // Every byte value, plus the empty blob.
        let payload = (0...255).map { UInt8($0) }
        _ = try await db.query("INSERT INTO pg_blobs (data) VALUES (?)", [.blob(payload)])
        _ = try await db.query("INSERT INTO pg_blobs (data) VALUES (?)", [.blob([])])

        let rows = try await db.query("SELECT data FROM pg_blobs ORDER BY id", [])
        #expect(rows.rows[0] == [.blob(payload)])
        #expect(rows.rows[1] == [.blob([])])
        _ = try await db.query("DROP TABLE pg_blobs", [])
    }

    @Test(.enabled(if: postgresURL() != nil))
    func transactionsCommitAndRollBack() async throws {
        let db = try PostgresDriver.connect(url: postgresURL()!)
        _ = try await db.query("DROP TABLE IF EXISTS pg_tx", [])
        _ = try await db.query("CREATE TABLE pg_tx (id BIGSERIAL PRIMARY KEY, n BIGINT)", [])

        try await db.transaction { tx in
            _ = try await tx.query("INSERT INTO pg_tx (n) VALUES (?)", [.integer(1)])
            _ = try await tx.query("INSERT INTO pg_tx (n) VALUES (?)", [.integer(2)])
        }
        #expect(try await db.query("SELECT COUNT(*) FROM pg_tx", []).rows.first?[0] == .integer(2))

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.transaction { tx in
                _ = try await tx.query("INSERT INTO pg_tx (n) VALUES (?)", [.integer(3)])
                throw Boom()
            }
        }
        // The failed body's insert rolled back.
        #expect(try await db.query("SELECT COUNT(*) FROM pg_tx", []).rows.first?[0] == .integer(2))
        _ = try await db.query("DROP TABLE pg_tx", [])
    }

    @Test(.enabled(if: postgresURL() != nil))
    func poolServesConcurrentQueriesAndTransactionsDoNotSerialiseThem() async throws {
        let db = try PostgresDriver.connect(url: postgresURL()!)
        _ = try await db.query("DROP TABLE IF EXISTS pg_conc", [])
        _ = try await db.query("CREATE TABLE pg_conc (id BIGSERIAL PRIMARY KEY, n BIGINT)", [])

        // A held-open transaction must not block other requests' queries (the old
        // single-connection driver serialised everything behind it).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await db.transaction { tx in
                    _ = try await tx.query("INSERT INTO pg_conc (n) VALUES (?)", [.integer(0)])
                    _ = try await tx.query("SELECT pg_sleep(0.3)", [])
                }
            }
            for i in 1...8 {
                group.addTask {
                    _ = try await db.query("INSERT INTO pg_conc (n) VALUES (?)", [.integer(Int64(i))])
                }
            }
            try await group.waitForAll()
        }
        #expect(try await db.query("SELECT COUNT(*) FROM pg_conc", []).rows.first?[0] == .integer(9))
        _ = try await db.query("DROP TABLE pg_conc", [])
    }

    @Test(.enabled(if: postgresURL() != nil))
    func cancelledCheckoutLeavesTheQueue() async throws {
        let pool = PostgresPool(url: postgresURL()!, maxConnections: 1)
        let held = try await pool.checkout()

        // With the only connection held, a queued checkout that gets cancelled must
        // throw instead of waiting forever (and must not consume the connection).
        let waiting = Task { () -> Bool in
            do {
                _ = try await pool.checkout()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(50))   // let it enqueue
        waiting.cancel()
        #expect(await waiting.value)

        // The pool still works: check the connection back in and out again.
        await pool.checkin(held)
        let again = try await pool.checkout()
        await pool.checkin(again)
    }

    @Test(.enabled(if: postgresURL() != nil))
    func preparedStatementsSurviveSchemaChanges() async throws {
        let db = try PostgresDriver.connect(url: postgresURL()!)
        _ = try await db.query("DROP TABLE IF EXISTS pg_evolve", [])
        _ = try await db.query("CREATE TABLE pg_evolve (id BIGSERIAL PRIMARY KEY, a BIGINT)", [])
        _ = try await db.query("INSERT INTO pg_evolve (a) VALUES (?)", [.integer(1)])

        // Same SELECT * repeatedly → prepared and reused on one connection.
        for _ in 0..<3 {
            _ = try await db.query("SELECT * FROM pg_evolve WHERE a = ?", [.integer(1)])
        }
        // Changing the result shape invalidates the cached plan (SQLSTATE 0A000);
        // the driver must re-prepare and answer, not error.
        _ = try await db.query("ALTER TABLE pg_evolve ADD COLUMN b TEXT", [])
        let after = try await db.query("SELECT * FROM pg_evolve WHERE a = ?", [.integer(1)])
        #expect(after.columns.count == 3)
        _ = try await db.query("DROP TABLE pg_evolve", [])
    }
}
