import PlumeCore

// Hand-authored, versioned schema migrations: you write each change once, the
// Migrator applies it exactly once and records it in a ledger.
//
// This is the deliberate counterpart to `migrate(_ schemas:)`: that one INFERS
// DDL by diffing the @Model types and can only render a lossy projection (no
// NOT NULL / DEFAULT / foreign keys / indexes / CHECK / drops). A `Migration`
// runs the exact `up`/`down` you write — SQL or arbitrary Swift — so it expresses
// everything a real schema needs. Nothing is auto-generated; the Migrator applies
// pending migrations in order and can roll the latest back.
//
// Migrations and seeders run natively (the CLI / a build step), never in the Wasm
// guest — but the types stay defined on every target so an app's `runMigrations`
// compiles everywhere without a per-app `#if`. In the guest the run methods are
// no-ops (nothing calls them there).

public enum MigrationError: Error, Sendable {
    case irreversible(String)
    case noSuchSeeder(String)
}

// MARK: - Migration

/// One versioned, reversible change. `up` applies it; `down` (optional) reverses
/// it. The Migrator runs `up`s in ascending `version` order. `version` is the
/// identity + ordering key — a zero-padded number or timestamp, e.g.
/// "0001_initial_schema" or "20260703_120000_add_widgets".
public struct Migration: Sendable {
    public let version: String
    public let up: @Sendable (Database) async throws -> Void
    public let down: (@Sendable (Database) async throws -> Void)?

    public init(version: String,
                up: @escaping @Sendable (Database) async throws -> Void,
                down: (@Sendable (Database) async throws -> Void)? = nil) {
        self.version = version
        self.up = up
        self.down = down
    }

    /// The common case: a migration whose up/down are SQL scripts. Multiple
    /// `;`-separated statements run in order; `--` line comments are ignored. This
    /// is all an app needs to hand-author a full-fidelity schema.
    public static func sql(version: String, up: String, down: String? = nil) -> Migration {
        let runUp: @Sendable (Database) async throws -> Void = { db in
            for statement in splitSQLStatements(up) { _ = try await db.query(statement, []) }
        }
        var runDown: (@Sendable (Database) async throws -> Void)? = nil
        if let down {
            runDown = { db in
                for statement in splitSQLStatements(down) { _ = try await db.query(statement, []) }
            }
        }
        return Migration(version: version, up: runUp, down: runDown)
    }
}

// MARK: - Migrator

private let migratorLedger = "schema_migrations"

/// Applies and rolls back an ordered set of migrations, tracking what has run in
/// its own `schema_migrations` ledger. `migrate` applies pending migrations in
/// order; `rollback` reverses the most recent; `status` reports both.
public struct Migrator: Sendable {
    public let migrations: [Migration]

    public init(_ migrations: [Migration]) { self.migrations = migrations }

    /// Apply every not-yet-applied migration in ascending version order; returns
    /// the versions that ran.
    ///
    /// `adoptExistingTable`: when the ledger is empty but this table already
    /// exists — a database built before this migration set (an adopted legacy
    /// schema) — every migration is recorded as applied WITHOUT running, so a live
    /// production schema is never re-created or re-altered. Pass `nil` to always
    /// apply from scratch (a fresh database).
    @discardableResult
    public func migrate(in db: Database, adoptExistingTable: String? = nil) async throws -> [String] {
        try await ensureLedger(in: db)
        let ordered = sortedMigrations()
        if let table = adoptExistingTable, try await ledgerIsEmpty(in: db),
           try await introspectColumns(table: table, in: db).isEmpty == false {
            for m in ordered { try await markApplied(m.version, in: db) }
            return []
        }
        var applied: [String] = []
        for m in ordered where try await isApplied(m.version, in: db) == false {
            try await m.up(db)
            try await markApplied(m.version, in: db)
            applied.append(m.version)
        }
        return applied
    }

    /// Reverse the most recently applied `steps` migrations, newest first.
    @discardableResult
    public func rollback(in db: Database, steps: Int = 1) async throws -> [String] {
        try await ensureLedger(in: db)
        var reverted: [String] = []
        for m in sortedMigrations().reversed() {
            if reverted.count >= steps { break }
            if try await isApplied(m.version, in: db) {
                guard let down = m.down else {
                    #if hasFeature(Embedded)
                    return reverted   // migrations never run in the guest; keeps the type embedded-clean
                    #else
                    throw MigrationError.irreversible(m.version)
                    #endif
                }
                try await down(db)
                try await markReverted(m.version, in: db)
                reverted.append(m.version)
            }
        }
        return reverted
    }

    /// Each migration and whether it has been applied (in order).
    public func status(in db: Database) async throws -> [(version: String, applied: Bool)] {
        try await ensureLedger(in: db)
        var out: [(version: String, applied: Bool)] = []
        for m in sortedMigrations() { out.append((m.version, try await isApplied(m.version, in: db))) }
        return out
    }

    private func sortedMigrations() -> [Migration] {
        migrations.sorted { asciiLess($0.version, $1.version) }
    }
}

// MARK: - Ledger (its own table, independent of the model-diff migrator)

private func ensureLedger(in db: Database) async throws {
    let appliedAtType: String
    switch db.dialect {
    case .sqlite: appliedAtType = "INTEGER"     // already 64-bit on SQLite/D1
    case .postgres: appliedAtType = "BIGINT"
    }
    _ = try await db.query(
        "CREATE TABLE IF NOT EXISTS " + migratorLedger
        + " (version TEXT PRIMARY KEY, applied_at " + appliedAtType + ")", [])
}

private func ledgerIsEmpty(in db: Database) async throws -> Bool {
    try await db.query("SELECT 1 FROM " + migratorLedger + " LIMIT 1", []).rows.isEmpty
}

private func isApplied(_ version: String, in db: Database) async throws -> Bool {
    try await db.query(
        "SELECT 1 FROM " + migratorLedger + " WHERE version = ? LIMIT 1",
        [sqlText(version)]).rows.isEmpty == false
}

private func markApplied(_ version: String, in db: Database, at now: Int64 = ORMClock.now()) async throws {
    _ = try await db.query(
        "INSERT INTO " + migratorLedger + " (version, applied_at) VALUES (?, ?)",
        [sqlText(version), sqlInt(now)])
}

private func markReverted(_ version: String, in db: Database) async throws {
    _ = try await db.query(
        "DELETE FROM " + migratorLedger + " WHERE version = ?", [sqlText(version)])
}

// MARK: - Ledger-aware pending SQL (for D1 / any push-based backend)
//
// `plumekit migrate --local|--remote` can't run migrations inside the wasm worker,
// and it must NOT re-derive the whole schema as `CREATE TABLE IF NOT EXISTS` (that's
// additive-only — an ALTER on an already-created table would never land). Instead we
// read the TARGET's ledger, compute the pending migrations, and emit exactly those
// migrations' real `up()` statements plus their ledger inserts — captured by running
// each `up()` against a RECORDING Database that records SQL instead of executing it.
//
// Native-only (runs from the CLI/Server, never the guest) and serializes bound values
// — including Double — to SQL literals, so it stays out of the Embedded build.
#if !hasFeature(Embedded)

/// The SQL to bring a target up to date, plus the versions it will apply.
public struct PendingMigrationPlan: Sendable {
    /// A bare statement sequence — no `BEGIN`/`COMMIT` framing (Cloudflare D1 rejects
    /// explicit transactions/SAVEPOINTs in executed SQL, and `wrangler d1 execute
    /// --file` is atomic on its own): a `PRAGMA foreign_keys = OFF;`, the ledger
    /// `CREATE TABLE IF NOT EXISTS`, then each pending migration's `up()` statements
    /// and its `schema_migrations` insert.
    public let sql: String
    /// The versions `sql` applies, in order — empty when the target is already current.
    public let pending: [String]

    public init(sql: String, pending: [String]) {
        self.sql = sql
        self.pending = pending
    }
}

extension Migrator {
    /// Emit the SQL that advances a database whose ledger already holds
    /// `appliedVersions` up to the latest migration: the exact `up()` statements of
    /// the PENDING migrations only, followed by their ledger inserts, ready to hand to
    /// `wrangler d1 execute --file`. Nothing is executed — each `up()` runs against a
    /// recording `Database` that captures its statements (and any bound parameters,
    /// inlined as SQL literals) instead of touching a real backend. The ledger
    /// `CREATE TABLE IF NOT EXISTS` and INSERT format come straight from the Migrator's
    /// own helpers, so a later native `migrate` sees a consistent ledger.
    ///
    /// `now` is the epoch value written as each row's `applied_at`, threaded in so the
    /// output is deterministic.
    ///
    /// Limitation: a migration whose `up()` READS the database and branches on the
    /// result can't be captured — the recording DB returns an empty result. Pure
    /// DDL/writes (the norm) capture faithfully.
    public func pendingMigrationSQL(appliedVersions: [String],
                                    dialect: SQLDialectKind = .sqlite,
                                    now: Int64) async throws -> PendingMigrationPlan {
        let recorder = MigrationSQLRecorder()
        let db = Database(query: { sql, params in
            recorder.record(sql, params)
            return QueryResult(columns: [], rows: [], rowsAffected: 0, lastInsertID: 0)
        }, dialect: dialect)

        try await ensureLedger(in: db)                  // captures the ledger CREATE
        var pending: [String] = []
        for m in sortedMigrations() where isVersionApplied(m.version, in: appliedVersions) == false {
            try await m.up(db)                          // captures the migration's real DDL/DML
            try await markApplied(m.version, in: db, at: now)   // captures the ledger INSERT
            pending.append(m.version)
        }

        var out = "PRAGMA foreign_keys = OFF;\n"
        for statement in recorder.statements {
            out += inlineSQLLiterals(statement.sql, statement.params) + ";\n"
        }
        return PendingMigrationPlan(sql: out, pending: pending)
    }
}

/// Captures the statements a recording `Database` is asked to run. A final class so the
/// Sendable query closure can mutate it; migrations run sequentially (each `up()` is
/// awaited in turn), so the unsynchronized access is safe.
private final class MigrationSQLRecorder: @unchecked Sendable {
    var statements: [(sql: String, params: [SQLValue])] = []
    func record(_ sql: String, _ params: [SQLValue]) { statements.append((sql, params)) }
}

/// Byte-wise membership — never `String ==` on a version (the Unicode Link Law).
private func isVersionApplied(_ version: String, in applied: [String]) -> Bool {
    for a in applied where asciiEqual(a, version) { return true }
    return false
}

/// Inline positional `?` placeholders with their bound values as SQL literals so a
/// captured parametrized statement becomes standalone. A `?` inside a single-quoted
/// string is left alone; empty params → the statement verbatim.
private func inlineSQLLiterals(_ sql: String, _ params: [SQLValue]) -> String {
    if params.isEmpty { return sql }
    var out: [UInt8] = []
    var inSingleQuote = false
    var next = 0
    for b in Array(sql.utf8) {
        if b == 0x27 { inSingleQuote.toggle(); out.append(b); continue }   // '
        if b == 0x3F, !inSingleQuote, next < params.count {                // ?
            out.append(contentsOf: Array(migrationSQLLiteral(params[next]).utf8))
            next += 1
            continue
        }
        out.append(b)
    }
    return String(decoding: out, as: UTF8.self)
}

/// One SQLValue as a SQL literal (mirrors PlumeServer's dump serializer; kept here so
/// PlumeORM keeps no dependency on the native dump). Byte-wise string escaping.
private func migrationSQLLiteral(_ value: SQLValue) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let n): return String(n)
    case .double(let d): return String(d)
    case .text(let s): return "'" + escapedMigrationString(s) + "'"
    case .blob(let bytes): return "x'" + migrationHexString(bytes) + "'"
    }
}

private func escapedMigrationString(_ s: String) -> String {
    var out = ""
    for ch in s { if ch == "'" { out += "''" } else { out.append(ch) } }
    return out
}

private func migrationHexString(_ bytes: [UInt8]) -> String {
    var scalars: [UInt8] = []
    for b in bytes {
        scalars.append(migrationHexDigit(b >> 4))
        scalars.append(migrationHexDigit(b & 0x0f))
    }
    return String(decoding: scalars, as: UTF8.self)
}

private func migrationHexDigit(_ n: UInt8) -> UInt8 { n < 10 ? (0x30 + n) : (0x61 + n - 10) }

#endif

// MARK: - Seeders

/// A unit of seed data. `run`
/// inserts rows; compose by calling other seeders inside `run`. Seeders are
/// re-runnable by design — make them idempotent (upsert) if you may run them
/// more than once.
public struct Seeder: Sendable {
    public let run: @Sendable (Database) async throws -> Void
    public init(_ run: @escaping @Sendable (Database) async throws -> Void) { self.run = run }
}

/// Run seeders in order.
public func runSeeders(_ seeders: [Seeder], in db: Database) async throws {
    for seeder in seeders { try await seeder.run(db) }
}

/// Run named seeders — all of them, or just the one whose name matches `only`
/// (case-insensitively, with or without a trailing "Seeder"). Throws if `only`
/// names no seeder, so a typo fails loudly instead of silently seeding nothing.
public func runSeeders(_ seeders: [(name: String, seeder: Seeder)],
                       only: String? = nil, in db: Database) async throws {
    guard let only else {
        for entry in seeders { try await entry.seeder.run(db) }
        return
    }
    // Name matching runs natively only (`plumekit seed <name>`). It uses case-folding
    // and String comparison, which pull in Unicode tables that don't link in the Wasm
    // guest — so keep the whole selection path out of the embedded build.
    #if !hasFeature(Embedded)
    let wanted = seederKey(only)
    var ran = false
    for entry in seeders where seederKey(entry.name) == wanted {
        try await entry.seeder.run(db)
        ran = true
    }
    if !ran { throw MigrationError.noSuchSeeder(only) }
    #endif
}

#if !hasFeature(Embedded)
private func seederKey(_ name: String) -> String {
    var key = name.lowercased()
    if key.hasSuffix("seeder") { key = String(key.dropLast("seeder".count)) }
    return key
}
#endif

// MARK: - Byte-wise helpers (Foundation-free, embedded-safe)

/// Split a SQL script into executable statements: `;`-terminated (outside single
/// quotes), with `--` line comments stripped and surrounding whitespace trimmed.
public func splitSQLStatements(_ sql: String) -> [String] {
    var statements: [String] = []
    var current: [UInt8] = []
    let bytes = Array(sql.utf8)
    let n = bytes.count
    var i = 0
    var inSingleQuote = false
    while i < n {
        let b = bytes[i]
        if !inSingleQuote, b == 0x2D, i + 1 < n, bytes[i + 1] == 0x2D {   // "--" line comment
            while i < n, bytes[i] != 0x0A { i += 1 }                       // skip to newline
            continue
        }
        if b == 0x27 { inSingleQuote.toggle() }                            // ' toggles a string literal
        if b == 0x3B, !inSingleQuote {                                     // ; ends a statement
            appendTrimmed(&statements, current)
            current = []
            i += 1
            continue
        }
        current.append(b)
        i += 1
    }
    appendTrimmed(&statements, current)
    return statements
}

private func appendTrimmed(_ out: inout [String], _ bytes: [UInt8]) {
    var lo = 0
    var hi = bytes.count
    while lo < hi, isSQLSpace(bytes[lo]) { lo += 1 }
    while lo < hi, isSQLSpace(bytes[hi - 1]) { hi -= 1 }
    if lo >= hi { return }
    out.append(String(decoding: bytes[lo..<hi], as: UTF8.self))
}

private func isSQLSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

private func asciiLess(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    var i = 0
    while i < x.count, i < y.count {
        if x[i] != y[i] { return x[i] < y[i] }
        i += 1
    }
    return x.count < y.count
}
