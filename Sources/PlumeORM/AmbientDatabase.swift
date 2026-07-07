import PlumeCore

/// The database for an ORM operation: the explicit `in:` argument if you passed one, else
/// the ambient database of the current scope — a request, a `db.transaction { }`, or a
/// migration / seeder / job run (each binds `RequestContext.current`).
///
/// If none is available you're calling the ORM outside any of those without an `in:` — a
/// programming error — so this traps with a clear message (embedded Swift can't throw a
/// custom error type). Pass `in: db` in tests.
func resolvedDatabase(_ explicit: Database?) -> Database {
    if let explicit { return explicit }
    #if !hasFeature(Embedded)
    // Inside `db.transaction { … }`, ambient ORM calls join the transaction
    // (task-local, so only the transaction's own task sees it).
    if let transaction = TransactionContext.database { return transaction }
    #endif
    if let current = RequestContext.current?.database { return current }
    fatalError("No database available. Pass `in: db`, or run inside a request, migration, "
        + "seeder, or job — those bind the database automatically.")
}
