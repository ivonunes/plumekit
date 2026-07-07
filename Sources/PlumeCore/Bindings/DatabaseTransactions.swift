import _Concurrency

// Interactive-transaction support for native backends (SQLite, Postgres). Excluded
// from the embedded-Wasm guest — D1 has no interactive transactions, and the task-
// local machinery below doesn't compile under Embedded. The `Database.transaction`
// entry point itself lives in Database.swift and is portable; only the runner that
// makes it real is native.
#if !hasFeature(Embedded)

/// The transaction the current task is inside, if any. The transaction runner binds
/// this around the body, so ambient ORM calls (`post.save()`) route to the
/// transaction connection instead of deadlocking against the connection lock.
/// Task-local: concurrent requests each see only their own transaction.
public enum TransactionContext {
    @TaskLocal public static var database: Database?
}

extension Database {
    /// Wrap `adapter` with interactive-transaction support over its single shared
    /// connection. Plain queries acquire a connection lock per statement, and a
    /// transaction holds that lock from BEGIN to COMMIT/ROLLBACK — so another
    /// request's statement can never slip inside an open transaction. Nested
    /// `transaction` calls join the outer transaction rather than starting a new one.
    public static func interactiveTransactions(
        _ adapter: some SQLDatabase, dialect: SQLDialectKind = .sqlite
    ) -> Database {
        let lock = ConnectionLock()
        let raw: Querier = { sql, parameters in try await adapter.query(sql, parameters) }

        // The handle handed to a transaction body: queries go straight to the
        // connection (the caller already holds the lock), and a nested transaction
        // just runs its body against the same handle.
        @Sendable func transactionHandle() -> Database {
            Database(query: raw, dialect: dialect,
                     transaction: { body in try await body(transactionHandle()) })
        }

        return Database(
            query: { sql, parameters in
                // If THIS task is already inside a transaction, join it: a body that
                // accidentally captures the outer handle (`db.query` instead of
                // `tx.query`) must not deadlock against the lock its own
                // transaction holds.
                if TransactionContext.database != nil {
                    return try await raw(sql, parameters)
                }
                await lock.acquire()
                do {
                    let result = try await raw(sql, parameters)
                    await lock.release()
                    return result
                } catch {
                    await lock.release()
                    throw error
                }
            },
            dialect: dialect,
            transaction: { body in
                // Same protection: `db.transaction` inside a transaction joins it,
                // exactly like a nested `tx.transaction`.
                if let joined = TransactionContext.database {
                    try await body(joined)
                    return
                }
                await lock.acquire()
                do {
                    _ = try await raw("BEGIN", [])
                    let tx = transactionHandle()
                    try await TransactionContext.$database.withValue(tx) {
                        try await body(tx)
                    }
                    _ = try await raw("COMMIT", [])
                    await lock.release()
                } catch {
                    _ = try? await raw("ROLLBACK", [])
                    await lock.release()
                    throw error
                }
            })
    }
}

/// A FIFO async mutex over the adapter's single connection. A resumed waiter takes
/// ownership directly (`locked` stays true), so hand-off is fair and race-free.
actor ConnectionLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

#endif
