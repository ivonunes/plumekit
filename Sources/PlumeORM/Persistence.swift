import PlumeCore
import _Concurrency

// Active-record persistence, written ONCE generically over `Model` + the neutral
// `Database` handle (which is the SQL tier — wraps `some SQLDatabase`). Works
// identically on D1 and native SQLite; never names a platform type.
//
// All SQL is built by ASCII append (column names are protocol tokens); VALUES are
// always bound parameters (`?`), never interpolated. No Unicode-aware String ops.

extension Model {
    /// Minimal create-if-not-exists from the model's schema. NOT the migration
    /// system: no diffing, versioning, or reversibility — just enough for
    /// tests and zero-config local dev. The DDL is rendered with the DATABASE's
    /// dialect (the same per-dialect `columnDefinition` the migrator uses), so the
    /// same call works on SQLite/D1 AND Postgres with no app change.
    public static func createTable(in db: Database? = nil) async throws {
        let db = resolvedDatabase(db)
        let sql: String
        switch db.dialect {
        case .sqlite: sql = createTableSQL(SQLiteDialect())
        case .postgres: sql = createTableSQL(PostgresDialect())
        }
        _ = try await db.query(sql, [])
    }

    private static func createTableSQL(_ dialect: some SQLDialect) -> String {
        var defs: [String] = []
        for column in schema.columns {
            var def = dialect.columnDefinition(column)
            if !column.isNullable && !column.isPrimaryKey { def += " NOT NULL" }   // match the migration builder
            defs.append(def)
        }
        return "CREATE TABLE IF NOT EXISTS " + schema.table + " (" + joined(defs, ", ") + ")"
    }

    /// Drop this model's table if it exists. The reverse of `createTable`; use it as
    /// the `down` step of a migration that creates the table.
    public static func dropTable(in db: Database? = nil) async throws {
        let db = resolvedDatabase(db)
        _ = try await db.query("DROP TABLE IF EXISTS " + schema.table, [])
    }

    /// Delete every row in this model's table, leaving the table itself. Useful in
    /// seeders and test setup to start from a clean slate.
    public static func truncate(in db: Database? = nil) async throws {
        let db = resolvedDatabase(db)
        _ = try await db.query("DELETE FROM " + schema.table, [])
    }

    /// INSERT a new row and populate a database-generated integer `id`, or UPDATE
    /// only the columns that changed since the last save/load (dirty tracking).
    /// No-op UPDATE if nothing changed.
    /// Validate, then persist. Returns validation errors (and does NOT persist) if
    /// invalid, or [] on success. Validation failure is a returned value, not a
    /// thrown error — embedded Swift forbids `catch as`/`any Error` dynamic casts,
    /// so this keeps the same code working natively and in the wasm worker. (Real
    /// DB errors still `throw` and propagate.)
    @discardableResult
    public func save(in db: Database? = nil) async throws -> [ValidationError] {
        let db = resolvedDatabase(db)
        let errors = try await validate(in: db)
        if !errors.isEmpty { return errors }
        try await willSave()
        let creating = !isPersisted
        touchTimestamps(creating: creating)   // createdAt on INSERT, updatedAt always
        let values = columnValues()
        if creating {
            var names: [String] = []
            var bound: [SQLValue] = []
            for (i, column) in Self.schema.columns.enumerated() where !column.isDatabaseGenerated {
                names.append(column.name)
                bound.append(values[i])
            }
            let sql = "INSERT INTO " + Self.schema.table + " ("
                + joined(names, ", ") + ") VALUES (" + placeholders(names.count) + ")"
            // SQLite/D1 hand back the new rowid via lastInsertID; Postgres doesn't,
            // so ask for it with RETURNING <pk>. UUID/string keys are supplied by
            // app code and don't need a returned value.
            if Self.databaseGeneratedPrimaryKey {
                switch db.dialect {
                case .postgres:
                    let result = try await db.query(sql + " RETURNING " + Self.primaryKeyColumn, bound)
                    if let first = result.rows.first { setDatabaseGeneratedID(Row(first).int64(0)) }
                case .sqlite:
                    let result = try await db.query(sql, bound)
                    // The model's hook stores the rowid at the PK's real width — full 64-bit
                    // for an `Int64` PK, wrapped for a 32-bit-guest `Int` PK.
                    setDatabaseGeneratedID(result.lastInsertID)
                }
            } else {
                _ = try await db.query(sql, bound)
            }
            markPersisted()
            refreshRelations()   // bind has-many handles to the new id
        } else {
            var assignments: [String] = []
            var bound: [SQLValue] = []
            for i in changedColumnIndices() {
                let column = Self.schema.columns[i]
                if column.isPrimaryKey { continue }
                assignments.append(column.name + " = ?")
                bound.append(values[i])
            }
            if assignments.isEmpty { return [] }   // clean — nothing to write
            bound.append(primaryKeyValue)
            let sql = "UPDATE " + Self.schema.table + " SET "
                + joined(assignments, ", ") + " WHERE " + Self.primaryKeyColumn + " = ?"
            _ = try await db.query(sql, bound)
        }
        takeSnapshot()
        try await didSave()
        return []
    }

    /// INSERT-or-UPDATE keyed on the primary key, supplying the PK value explicitly
    /// (`INSERT … ON CONFLICT(<pk>) DO UPDATE SET …`). Unlike `save()` — which decides
    /// INSERT vs UPDATE from `id == 0` and never lets the caller choose the id — `upsert`
    /// writes the row at a CALLER-CHOSEN primary key. This is what seeding/importing
    /// fixed-id reference data needs (rows whose ids are authored, not auto-assigned), and
    /// it is idempotent: re-running produces the same rows. Validations run first.
    ///
    /// Timestamps are touched as `creating: true` for the inserted values; on conflict
    /// every non-PK column except `created_at` is overwritten from the proposed row, so
    /// re-running an upsert (e.g. a seeder) keeps the original creation time.
    @discardableResult
    public func upsert(in db: Database? = nil) async throws -> [ValidationError] {
        let db = resolvedDatabase(db)
        let errors = try await validate(in: db)
        if !errors.isEmpty { return errors }
        try await willSave()
        touchTimestamps(creating: true)
        let values = columnValues()

        var names: [String] = []
        for column in Self.schema.columns { names.append(column.name) }
        var setClauses: [String] = []
        var pkName = "id"
        for column in Self.schema.columns {
            if column.isPrimaryKey { pkName = column.name; continue }
            // Preserve creation time on conflict — by the model's REAL created-at column
            // (honors an @Column rename), not a hardcoded "created_at".
            if let createdAt = Self.createdAtColumn, utf8Equal(column.name, createdAt) { continue }
            setClauses.append(column.name + " = excluded." + column.name)
        }

        var sql = "INSERT INTO " + Self.schema.table + " (" + joined(names, ", ")
            + ") VALUES (" + placeholders(names.count) + ") ON CONFLICT(" + pkName + ") DO "
        // A PK-only table has nothing to update on conflict → DO NOTHING.
        sql += setClauses.isEmpty ? "NOTHING" : "UPDATE SET " + joined(setClauses, ", ")
        _ = try await db.query(sql, values)
        markPersisted()
        takeSnapshot()
        try await didSave()
        return []
    }

    /// DELETE this row by primary key — by the schema's PK column and this row's
    /// `primaryKeyValue`, so it works for an integer `id` AND a custom (e.g. String) PK.
    public func delete(in db: Database? = nil) async throws {
        let db = resolvedDatabase(db)
        try await willDelete()
        _ = try await db.query("DELETE FROM " + Self.schema.table + " WHERE " + Self.primaryKeyColumn + " = ?", [primaryKeyValue])
        try await didDelete()
    }

    /// Route model binding: fetch the row whose id is in the request's path, or nil.
    /// Turns the show/update/destroy preamble into one guard:
    ///
    ///     guard let post = try await Post.find(request) else { return .status(404) }
    ///
    /// Reads `request.parameters[parameter]` (`:id` by convention — pass
    /// `parameter: "post_id"` for nested routes) and finds by primary key, keyed by the
    /// model's PK type: an integer PK parses the segment as Int64; a UUID/String PK uses
    /// the raw segment. Returns nil when the segment is missing or not a valid integer.
    public static func find(_ request: Request, parameter: String = "id",
                            in db: Database? = nil) async throws -> Self? {
        guard let raw = request.parameters[parameter] else { return nil }
        if case .integer = primaryKeyColumnType {
            // Parse as Int64, not Int — `Int` is 32-bit on the Wasm guest, so a large D1
            // rowid (> 2^31) on an Int64 PK would overflow to nil and 404 a real row.
            guard let id = Int64(raw) else { return nil }
            return try await find(id, in: db)
        }
        if case .uuid = primaryKeyColumnType {
            // Canonicalize (lowercase, validate) so an upper- or mixed-case segment still
            // matches the stored lowercase-canonical UUID.
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return try await find(uuid, in: db)
        }
        return try await find(raw, in: db)   // plain String key: the raw path segment
    }

    /// Fetch one row by primary key, or nil. Respects the model's `defaultScope`
    /// (a soft-deleted row is not found; use `withTrashed().where(...)` to reach it).
    public static func find<Value: SQLValueConvertible>(_ id: Value, in db: Database? = nil) async throws -> Self? {
        let db = resolvedDatabase(db)
        var sql = "SELECT " + selectColumns(schema) + " FROM " + schema.table
            + " WHERE " + primaryKeyColumn + " = ?"
        var bindings: [SQLValue] = [id.asSQLValue]
        if let scope = defaultScope {
            sql += " AND (" + scope.sql + ")"
            bindings.append(contentsOf: scope.bindings)
        }
        sql += " LIMIT 1"
        let result = try await db.query(sql, bindings)
        guard let row = result.rows.first else { return nil }
        return Self(row: Row(row))
    }
}

// MARK: - SQL building helpers (ASCII, byte-safe)

func sqlColumnType(_ type: ColumnType) -> String {
    switch type {
    case .integer, .boolean: return "INTEGER"
    case .uuid: return "TEXT"
    case .text: return "TEXT"
    case .real: return "REAL"
    case .blob: return "BLOB"
    }
}

/// `col1, col2, …` in schema order (for SELECT projection — matches positional
/// decode in `init(row:)`).
func selectColumns(_ schema: TableSchema) -> String {
    var names: [String] = []
    for column in schema.columns { names.append(column.name) }
    return joined(names, ", ")
}

/// `?, ?, …` — n bound-parameter placeholders.
func placeholders(_ count: Int) -> String {
    var out = ""
    var i = 0
    while i < count {
        if i > 0 { out += ", " }
        out += "?"
        i += 1
    }
    return out
}

/// Join ASCII tokens with a separator by append (never `Array.joined`, to stay
/// clear of any Unicode-table dependency under embedded wasm).
func joined(_ parts: [String], _ separator: String) -> String {
    var out = ""
    var first = true
    for part in parts {
        if !first { out += separator }
        first = false
        out += part
    }
    return out
}
