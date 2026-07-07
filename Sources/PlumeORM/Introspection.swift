import PlumeCore
import _Concurrency

// Schema introspection through the neutral SQLDatabase — the basis for diffing
// a model's TableSchema against the live database. `PRAGMA table_info` works on
// both native SQLite and Cloudflare D1 (D1 is SQLite); Postgres introspection
// (information_schema) is a later dialect addition. Decode is POSITIONAL (PRAGMA's
// column order), never by name — so no Unicode-aware String comparison is needed.

public struct ColumnInfo: Sendable {
    public let name: String
    public let declaredType: String
    public let notNull: Bool
    public let isPrimaryKey: Bool

    public init(name: String, declaredType: String, notNull: Bool, isPrimaryKey: Bool) {
        self.name = name
        self.declaredType = declaredType
        self.notNull = notNull
        self.isPrimaryKey = isPrimaryKey
    }
}

/// Current columns of `table`, or [] if the table does not exist. Dialect-aware:
/// SQLite/D1 use `PRAGMA table_info`; Postgres uses `information_schema.columns`.
/// The dialect comes from the `Database` handle, so the migrator is portable with
/// no app change.
public func introspectColumns(table: String, in db: Database) async throws -> [ColumnInfo] {
    switch db.dialect {
    case .sqlite: return try await introspectSQLite(table: table, in: db)
    case .postgres: return try await introspectPostgres(table: table, in: db)
    }
}

/// `PRAGMA table_info` (columns: 0 cid, 1 name, 2 type, 3 notnull, 4 dflt, 5 pk).
private func introspectSQLite(table: String, in db: Database) async throws -> [ColumnInfo] {
    // Table name is an ASCII schema token (not user input); PRAGMA can't bind it.
    let result = try await db.query("PRAGMA table_info(" + table + ")", [])
    var columns: [ColumnInfo] = []
    for rawRow in result.rows {
        let row = Row(rawRow)
        columns.append(ColumnInfo(
            name: row.string(1),
            declaredType: row.string(2),
            notNull: row.int(3) != 0,
            isPrimaryKey: row.int(5) != 0))
    }
    return columns
}

/// `information_schema.columns` (parameter-bound table name). Decode positional:
/// 0 column_name, 1 data_type, 2 not-null flag.
private func introspectPostgres(table: String, in db: Database) async throws -> [ColumnInfo] {
    let result = try await db.query(
        "SELECT column_name, data_type, CASE WHEN is_nullable = 'NO' THEN 1 ELSE 0 END"
        + " FROM information_schema.columns WHERE table_name = ? ORDER BY ordinal_position",
        [sqlText(table)])
    var columns: [ColumnInfo] = []
    for rawRow in result.rows {
        let row = Row(rawRow)
        columns.append(ColumnInfo(
            name: row.string(0),
            declaredType: row.string(1),
            notNull: row.int(2) != 0,
            isPrimaryKey: false))   // diff matches by name; createTable/migrate set the PK
    }
    return columns
}

/// Byte-wise ASCII name comparison (never `String ==`, which fails to link under
/// embedded wasm).
public func asciiEqual(_ a: String, _ b: String) -> Bool {
    Array(a.utf8) == Array(b.utf8)
}

/// Case-insensitive ASCII name comparison — SQL identifiers are case-insensitive
/// (Postgres folds unquoted names to lowercase; SQLite is case-insensitive too), so
/// schema-vs-introspection column matching must fold case to stay portable. Byte-
/// wise.
public func asciiEqualFold(_ a: String, _ b: String) -> Bool {
    let au = Array(a.utf8), bu = Array(b.utf8)
    if au.count != bu.count { return false }
    for i in 0..<au.count {
        let x = (au[i] >= 65 && au[i] <= 90) ? au[i] + 32 : au[i]
        let y = (bu[i] >= 65 && bu[i] <= 90) ? bu[i] + 32 : bu[i]
        if x != y { return false }
    }
    return true
}
