import PlumeCore

// Builders for writing schema changes explicitly in migrations. Spelling changes out
// keeps a migration a frozen record: it does not read the live `@Model`, so editing a
// model later never rewrites past migrations. (For a fresh table that always matches
// the current model — tests, throwaway dev databases — use `Model.createTable`; for
// versioned schema history, use these.)
//
//   try await db.createTable("posts") { t in
//       t.id()
//       t.text("title")
//       t.references("author", table: "users")   // author_id + foreign key
//       t.timestamps()
//   }
//   try await db.alterTable("posts") { t in
//       t.addColumn("slug", .text, nullable: true)
//       t.renameColumn("title", to: "headline")
//       t.dropColumn("legacy_flag")
//   }
//   try await db.addIndex(on: "posts", columns: ["author_id"])
//
// Every change is a portable statement (SQLite/D1 and Postgres). Renaming and dropping
// columns need SQLite 3.25+/3.35+ respectively — Cloudflare D1 and recent SQLite have
// both. For anything a builder doesn't cover, run `db.query("...")` directly.

// A column plus an optional trailing clause (e.g. a foreign-key reference).
struct ColumnSpec {
    let schema: ColumnSchema
    let suffix: String
}

public final class TableDefinition {
    var specs: [ColumnSpec] = []

    /// An auto-incrementing integer primary key (the conventional `id`).
    public func id(_ name: String = "id") {
        // isDatabaseGenerated: true so Postgres renders SERIAL even for a non-"id" name
        // (the default is only inferred for a column literally named "id").
        specs.append(ColumnSpec(
            schema: ColumnSchema(name: name, type: .integer, isPrimaryKey: true, isDatabaseGenerated: true),
            suffix: ""))
    }

    public func text(_ name: String, nullable: Bool = false) { add(name, .text, nullable) }
    public func integer(_ name: String, nullable: Bool = false) { add(name, .integer, nullable) }
    public func real(_ name: String, nullable: Bool = false) { add(name, .real, nullable) }
    public func boolean(_ name: String, nullable: Bool = false) { add(name, .boolean, nullable) }
    public func uuid(_ name: String, nullable: Bool = false) { add(name, .uuid, nullable) }
    public func blob(_ name: String, nullable: Bool = false) { add(name, .blob, nullable) }

    /// A foreign-key column: adds `<name>_id` referencing `table(column)`.
    public func references(_ name: String, table: String, column: String = "id", nullable: Bool = false) {
        let schema = ColumnSchema(name: name + "_id", type: .integer, isNullable: nullable)
        specs.append(ColumnSpec(schema: schema, suffix: " REFERENCES " + table + " (" + column + ")"))
    }

    /// `created_at` / `updated_at` as ISO-8601 text, matching a model that declares
    /// `var createdAt: String?` / `var updatedAt: String?`.
    public func timestamps() {
        add("created_at", .text, true)
        add("updated_at", .text, true)
    }

    private func add(_ name: String, _ type: ColumnType, _ nullable: Bool) {
        specs.append(ColumnSpec(schema: ColumnSchema(name: name, type: type, isNullable: nullable), suffix: ""))
    }
}

/// Column changes for `alterTable`. Each becomes its own `ALTER TABLE` statement,
/// applied in the order added.
public final class TableChanges {
    enum Change {
        case add(ColumnSpec)
        case drop(String)
        case rename(from: String, to: String)
    }
    var changes: [Change] = []

    public func addColumn(_ name: String, _ type: ColumnType, nullable: Bool = true) {
        changes.append(.add(ColumnSpec(schema: ColumnSchema(name: name, type: type, isNullable: nullable), suffix: "")))
    }

    /// Add a foreign-key column `<name>_id` referencing `table(column)`.
    public func addReference(_ name: String, table: String, column: String = "id", nullable: Bool = true) {
        let schema = ColumnSchema(name: name + "_id", type: .integer, isNullable: nullable)
        changes.append(.add(ColumnSpec(schema: schema, suffix: " REFERENCES " + table + " (" + column + ")")))
    }

    public func dropColumn(_ name: String) { changes.append(.drop(name)) }
    public func renameColumn(_ from: String, to: String) { changes.append(.rename(from: from, to: to)) }
}

extension Database {
    /// Create a table from an explicit column list, rendered for this database's
    /// dialect. Non-nullable columns get `NOT NULL`.
    public func createTable(_ name: String, _ define: (TableDefinition) -> Void) async throws {
        let table = TableDefinition()
        define(table)
        var defs: [String] = []
        for spec in table.specs { defs.append(columnDDL(spec, dialect: dialect)) }
        _ = try await query("CREATE TABLE " + name + " (" + joined(defs, ", ") + ")", [])
    }

    /// Drop a table if it exists. The reverse of `createTable`.
    public func dropTable(_ name: String) async throws {
        _ = try await query("DROP TABLE IF EXISTS " + name, [])
    }

    /// Rename a table.
    public func renameTable(_ from: String, to newName: String) async throws {
        _ = try await query("ALTER TABLE " + from + " RENAME TO " + newName, [])
    }

    /// Add, drop, or rename columns on an existing table.
    public func alterTable(_ name: String, _ change: (TableChanges) -> Void) async throws {
        let changes = TableChanges()
        change(changes)
        for c in changes.changes {
            let sql: String
            switch c {
            case .add(let spec):
                sql = "ALTER TABLE " + name + " ADD COLUMN " + columnDDL(spec, dialect: dialect)
            case .drop(let column):
                sql = "ALTER TABLE " + name + " DROP COLUMN " + column
            case .rename(let from, let to):
                sql = "ALTER TABLE " + name + " RENAME COLUMN " + from + " TO " + to
            }
            _ = try await query(sql, [])
        }
    }

    /// Create an index over one or more columns. The name defaults to
    /// `idx_<table>_<columns>`; keep it, you'll need it to drop the index.
    public func addIndex(on table: String, columns: [String], unique: Bool = false, name: String? = nil) async throws {
        let indexName = name ?? ("idx_" + table + "_" + joined(columns, "_"))
        let unique = unique ? "UNIQUE " : ""
        _ = try await query("CREATE " + unique + "INDEX " + indexName + " ON " + table + " (" + joined(columns, ", ") + ")", [])
    }

    public func dropIndex(_ name: String) async throws {
        _ = try await query("DROP INDEX IF EXISTS " + name, [])
    }
}

/// Column DDL: the dialect renders type + primary key; we append `NOT NULL` for
/// non-nullable, non-key columns and any trailing clause (e.g. a foreign key).
private func columnDDL(_ spec: ColumnSpec, dialect: SQLDialectKind) -> String {
    let column = spec.schema
    let base: String
    switch dialect {
    case .sqlite: base = SQLiteDialect().columnDefinition(column)
    case .postgres: base = PostgresDialect().columnDefinition(column)
    }
    let notNull = (!column.isNullable && !column.isPrimaryKey) ? " NOT NULL" : ""
    return base + notNull + spec.suffix
}
