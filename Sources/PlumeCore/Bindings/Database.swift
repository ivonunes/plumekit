import _Concurrency

// MARK: - The Database capability
//
// Platform-neutral SQL access. The protocol is the *adapter contract* (a D1
// adapter on Cloudflare, a SQLite/Postgres adapter natively both conform). The
// `Database` struct is the concrete, Embedded-clean handle carried through a
// request `Context` — it wraps any conforming adapter via an opaque `some`
// generic (NOT `any`), so the core never holds an existential and never names a
// platform type.
//
// Capability tiers: `Database` is the portable floor; `SQLDatabase` is the
// SQL-capable refinement. A key/value-only target would vend the floor; SQL
// handlers require the refinement.

/// A neutral SQL cell / bound parameter value. `[UInt8]` for blobs, no Foundation.
/// `text` holds a `String` for convenience — compare it byte-wise (the Unicode
/// Link Law), never with `String ==`, in Embedded code.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])
}

/// The result of a query: ordered columns, typed rows, and write metadata.
public struct QueryResult: Sendable {
    public let columns: [String]
    public let rows: [[SQLValue]]
    public let rowsAffected: Int
    public let lastInsertID: Int64

    public init(columns: [String], rows: [[SQLValue]], rowsAffected: Int, lastInsertID: Int64) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.lastInsertID = lastInsertID
    }
}

/// Which SQL dialect a database speaks — set by the ADAPTER (it knows its backend),
/// carried on the `Database` handle, and read by the ORM's migrator so app code
/// never names a dialect. (Lives in core as a plain tag because `SQLDialect` itself
/// is an ORM type; the ORM maps this tag → the concrete dialect.)
public enum SQLDialectKind: Sendable {
    case sqlite     // SQLite natively + D1 on Cloudflare
    case postgres   // Postgres (RDS/Aurora) natively
}

/// The base data binding (portable floor). Refinements add capabilities.
public protocol DataStore: Sendable {}

/// SQL-capable refinement — what an adapter implements (D1, SQLite, Postgres…).
public protocol SQLDatabase: DataStore {
    func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult
}

extension SQLDatabase {
    /// Convenience for parameter-less statements (DDL, plain SELECTs).
    @discardableResult
    public func query(_ sql: String) async throws -> QueryResult {
        try await query(sql, [])
    }
}

/// The concrete, Embedded-clean SQL handle carried in `Context`. Built from any
/// adapter conforming to `SQLDatabase` — wrapped via `some` (a specialized
/// generic), so no existential ever enters the core.
public struct Database: Sendable {
    public typealias Querier = @Sendable (String, [SQLValue]) async throws -> QueryResult
    /// Runs a transaction body against a transaction-scoped handle. Installed by
    /// adapters with interactive transactions (native SQLite, Postgres); nil where
    /// the backend has none (Cloudflare D1).
    public typealias TransactionRunner =
        @Sendable (_ body: @Sendable @escaping (Database) async throws -> Void) async throws -> Void

    private let _query: Querier
    private let _transaction: TransactionRunner?

    /// The dialect the backend speaks — the migrator reads this so app code never
    /// hardcodes a dialect (manifest swap changes the backend, not the app).
    public let dialect: SQLDialectKind

    /// Wrap a concrete adapter. `some SQLDatabase` keeps this generic/specialized
    /// (Embedded-clean) rather than an `any` existential.
    public init(_ adapter: some SQLDatabase, dialect: SQLDialectKind = .sqlite) {
        self._query = { try await adapter.query($0, $1) }
        self._transaction = nil
        self.dialect = dialect
    }

    /// Build directly from a closure (used by adapters that bridge via the host).
    public init(query: @escaping Querier, dialect: SQLDialectKind = .sqlite,
                transaction: TransactionRunner? = nil) {
        self._query = query
        self._transaction = transaction
        self.dialect = dialect
    }

    @discardableResult
    public func query(_ sql: String, _ parameters: [SQLValue] = []) async throws -> QueryResult {
        try await _query(sql, parameters)
    }

    /// Run `body` atomically: its writes commit together, and a thrown error rolls
    /// every one of them back (then rethrows). Queries on `tx` — and, on native
    /// servers, ambient ORM calls made inside the body — run inside the transaction;
    /// other requests' queries wait until it finishes.
    ///
    ///     let order = try await db.transaction { tx in
    ///         let order = Order(total: total)
    ///         _ = try await order.save(in: tx)
    ///         _ = try await tx.query("UPDATE inventory SET held = held + 1 WHERE sku = ?", [sku])
    ///         return order
    ///     }
    ///
    /// Available where the backend has interactive transactions (native SQLite,
    /// Postgres). Cloudflare D1 has none — each statement is atomic on its own —
    /// so calling this on D1 is a programming error and traps with a clear message.
    @discardableResult
    public func transaction<T>(_ body: @Sendable @escaping (Database) async throws -> T) async throws -> T {
        guard let _transaction else {
            fatalError("This database has no interactive transactions (Cloudflare D1 runs each "
                + "statement atomically on its own). Combine the writes into one statement, or "
                + "run them without a transaction.")
        }
        let box = TransactionResultBox<T>()
        try await _transaction { db in box.value = try await body(db) }
        guard let value = box.value else {
            fatalError("transaction runner returned without executing its body")
        }
        return value
    }
}

/// Carries the body's result out of the non-generic runner. The runner executes the
/// body exactly once before returning, so the unsynchronized access is safe.
private final class TransactionResultBox<T>: @unchecked Sendable {
    var value: T?
}
