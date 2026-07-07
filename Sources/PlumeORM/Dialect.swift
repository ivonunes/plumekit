import PlumeCore

// The per-backend SQL dialect: how a column is rendered in DDL (the SERIAL-vs-
// AUTOINCREMENT split). Read off the `Database` handle by the adapter, so app
// code never names a dialect — `Model.createTable` works on SQLite/D1 AND
// Postgres unchanged. Embedded-clean.

public protocol SQLDialect: Sendable {
    /// A full column DDL fragment, e.g. `id INTEGER PRIMARY KEY AUTOINCREMENT`
    /// (SQLite/D1) or `id SERIAL PRIMARY KEY` (Postgres).
    func columnDefinition(_ column: ColumnSchema) -> String
}

public struct SQLiteDialect: SQLDialect {
    public init() {}
    public func columnDefinition(_ column: ColumnSchema) -> String {
        var ddl = column.name + " " + sqliteType(column.type)
        if column.isPrimaryKey {
            ddl += column.isDatabaseGenerated && isInteger(column.type)
                ? " PRIMARY KEY AUTOINCREMENT"
                : " PRIMARY KEY"
        }
        return ddl
    }
    private func sqliteType(_ type: ColumnType) -> String {
        switch type {
        case .integer, .boolean: return "INTEGER"
        case .uuid: return "TEXT"
        case .text: return "TEXT"
        case .real: return "REAL"
        case .blob: return "BLOB"
        }
    }
    private func isInteger(_ type: ColumnType) -> Bool {
        if case .integer = type { return true }
        return false
    }
}

public struct PostgresDialect: SQLDialect {
    public init() {}
    public func columnDefinition(_ column: ColumnSchema) -> String {
        if column.isPrimaryKey && column.isDatabaseGenerated { return column.name + " BIGSERIAL PRIMARY KEY" }
        if column.isPrimaryKey { return column.name + " " + pgType(column.type) + " PRIMARY KEY" }
        return column.name + " " + pgType(column.type)
    }
    private func pgType(_ type: ColumnType) -> String {
        switch type {
        case .integer: return "BIGINT"
        case .uuid: return "UUID"
        case .boolean: return "BOOLEAN"
        case .text: return "TEXT"
        case .real: return "DOUBLE PRECISION"
        case .blob: return "BYTEA"
        }
    }
}
