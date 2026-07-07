import Testing
import PlumeCore
import PlumeServer

@Suite struct TransactionTests {
    struct Boom: Error {}

    private func makeDatabase() async throws -> Database {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        _ = try await db.query("CREATE TABLE entries (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
        return db
    }

    private func count(_ db: Database) async throws -> Int {
        let result = try await db.query("SELECT COUNT(*) FROM entries")
        guard case .integer(let n) = result.rows[0][0] else { return -1 }
        return Int(n)
    }

    @Test func commitPersistsAllWrites() async throws {
        let db = try await makeDatabase()
        try await db.transaction { tx in
            _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("a")])
            _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("b")])
        }
        #expect(try await count(db) == 2)
    }

    @Test func thrownErrorRollsBackAndRethrows() async throws {
        let db = try await makeDatabase()
        await #expect(throws: Boom.self) {
            try await db.transaction { tx in
                _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("a")])
                throw Boom()
            }
        }
        #expect(try await count(db) == 0)   // the insert was rolled back
    }

    @Test func returnsTheBodysValue() async throws {
        let db = try await makeDatabase()
        let id = try await db.transaction { tx in
            try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("a")]).lastInsertID
        }
        #expect(id == 1)
    }

    @Test func nestedTransactionJoinsTheOuterOne() async throws {
        let db = try await makeDatabase()
        await #expect(throws: Boom.self) {
            try await db.transaction { tx in
                try await tx.transaction { inner in
                    _ = try await inner.query("INSERT INTO entries (label) VALUES (?)", [.text("nested")])
                }
                throw Boom()   // must also roll back the nested insert
            }
        }
        #expect(try await count(db) == 0)
    }

    @Test func ambientTaskLocalIsBoundInsideTheBody() async throws {
        let db = try await makeDatabase()
        #expect(TransactionContext.database == nil)
        try await db.transaction { _ in
            #expect(TransactionContext.database != nil)
            // Ambient writes (what the ORM resolves to) join the transaction.
            _ = try await TransactionContext.database?.query(
                "INSERT INTO entries (label) VALUES (?)", [.text("ambient")])
        }
        #expect(TransactionContext.database == nil)
        #expect(try await count(db) == 1)
    }

    @Test func concurrentTransactionsSerializeWithoutInterleaving() async throws {
        let db = try await makeDatabase()
        // 8 concurrent transactions, each inserting two rows that must land together.
        // If BEGIN/COMMIT interleaved on the shared connection, SQLite would error
        // ("cannot start a transaction within a transaction") or counts would skew.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try await db.transaction { tx in
                        _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("t\(i)-1")])
                        _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("t\(i)-2")])
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try await count(db) == 16)
    }

    @Test func plainQueriesWaitForAnOpenTransaction() async throws {
        let db = try await makeDatabase()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await db.transaction { tx in
                    _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("in-tx")])
                    try await Task.sleep(nanoseconds: 50_000_000)   // hold the transaction open
                    _ = try await tx.query("INSERT INTO entries (label) VALUES (?)", [.text("in-tx-2")])
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000)       // start after BEGIN
                // This outer-handle write must NOT join the open transaction — it waits.
                _ = try await db.query("INSERT INTO entries (label) VALUES (?)", [.text("outside")])
            }
            try await group.waitForAll()
        }
        #expect(try await count(db) == 3)
    }
}

extension TransactionTests {
    @Test func outerHandleQueriesInsideABodyJoinInsteadOfDeadlocking() async throws {
        let db = try await makeDatabase()
        try await db.transaction { _ in
            // The classic one-character mistake: `db` instead of `tx`.
            _ = try await db.query("INSERT INTO entries (label) VALUES (?)", [.text("joined")])
        }
        #expect(try await count(db) == 1)
    }

    @Test func outerHandleTransactionInsideABodyJoinsToo() async throws {
        let db = try await makeDatabase()
        await #expect(throws: Boom.self) {
            try await db.transaction { _ in
                try await db.transaction { inner in
                    _ = try await inner.query("INSERT INTO entries (label) VALUES (?)", [.text("nested")])
                }
                throw Boom()
            }
        }
        #expect(try await count(db) == 0)   // joined → rolled back with the outer
    }
}
