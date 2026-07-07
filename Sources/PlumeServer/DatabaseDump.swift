import PlumeCore

// Serialize a live database to SQL — the mechanism behind `plumekit migrate/seed
// --local|--remote`. The wasm worker can't migrate or seed a D1 itself (that code
// is native-only), so the native Server materializes the schema and/or seed data
// in a throwaway in-memory database and dumps it; the CLI feeds the result to
// `wrangler d1 execute`. Foundation-free (byte-wise escaping).

public enum SQLDumpMode: Sendable {
    case schema   // CREATE TABLE/INDEX DDL + the migration ledger rows
    case seed     // row data for every table EXCEPT the migration ledger
    case all      // both — a complete setup script for a fresh database
}

/// Dump `db` as an idempotent SQL script for the requested slice. Rows are emitted
/// as `INSERT OR REPLACE` so the script is safe to re-run.
public func dumpDatabaseSQL(in db: Database, mode: SQLDumpMode = .all) async throws -> String {
    // No explicit BEGIN TRANSACTION/COMMIT: Cloudflare D1 rejects them ("use the
    // state.storage.transaction() APIs …") — its `d1 execute --file` import is already
    // atomic (rolls back on failure). Native `wrangler d1 execute --local` and a plain
    // sqlite load both accept a bare statement sequence too, so this is safe everywhere.
    var out = "PRAGMA foreign_keys = OFF;\n"

    // Every user table + its DDL, tables before their indexes.
    let master = try await db.query(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL "
        + "AND name NOT LIKE 'sqlite_%' ORDER BY (type = 'index'), name", [])
    var tables: [String] = []
    for row in master.rows where row.count >= 3 {
        guard case .text(let type) = row[0], case .text(let sql) = row[2] else { continue }
        if mode != .seed { out += idempotentDDL(sql) + ";\n" }
        if type == "table", case .text(let name) = row[1] { tables.append(name) }
    }

    for table in tables {
        // schema → only the migration ledger; seed → everything but it; all → everything.
        let isLedger = table == "schema_migrations"
        switch mode {
        case .schema where !isLedger: continue
        case .seed where isLedger: continue
        default: break
        }
        let result = try await db.query("SELECT * FROM " + table, [])
        if result.rows.isEmpty { continue }
        let columns = result.columns.joined(separator: ", ")
        for row in result.rows {
            var values: [String] = []
            for value in row { values.append(sqlLiteral(value)) }
            out += "INSERT OR REPLACE INTO " + table + " (" + columns + ") VALUES ("
                + values.joined(separator: ", ") + ");\n"
        }
    }
    return out
}

/// sqlite_master stores the original `CREATE …`; inject `IF NOT EXISTS` so re-running
/// the dump (e.g. a second `plumekit deploy` re-runs migrate against the live D1) is a
/// no-op instead of failing on "table already exists".
private func idempotentDDL(_ sql: String) -> String {
    for prefix in ["CREATE TABLE ", "CREATE UNIQUE INDEX ", "CREATE INDEX "] {
        if sql.hasPrefix(prefix), !sql.hasPrefix(prefix + "IF NOT EXISTS ") {
            return prefix + "IF NOT EXISTS " + String(sql.dropFirst(prefix.count))
        }
    }
    return sql
}

private func sqlLiteral(_ value: SQLValue) -> String {
    switch value {
    case .null: return "NULL"
    case .integer(let n): return String(n)
    case .double(let d): return String(d)
    case .text(let s): return "'" + escapedSQLString(s) + "'"
    case .blob(let bytes): return "x'" + hexString(bytes) + "'"
    }
}

private func escapedSQLString(_ s: String) -> String {
    var out = ""
    for ch in s { if ch == "'" { out += "''" } else { out.append(ch) } }
    return out
}

private func hexString(_ bytes: [UInt8]) -> String {
    var scalars: [UInt8] = []
    for b in bytes {
        scalars.append(hexDigit(b >> 4))
        scalars.append(hexDigit(b & 0x0f))
    }
    return String(decoding: scalars, as: UTF8.self)
}

private func hexDigit(_ n: UInt8) -> UInt8 { n < 10 ? (0x30 + n) : (0x61 + n - 10) }
