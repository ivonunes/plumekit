#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CPostgres
import PlumeCore

// Native Postgres SQLDatabase driver via the system libpq. Conforms to the same
// neutral `SQLDatabase` as SQLite and D1 — the proof that the abstraction takes a
// second, structurally-different SQL backend without bending.
//
// Two portability normalisations live here (the adapter's job, not the app's):
//   • `?` placeholders are rewritten to Postgres `$1,$2,…`.
//   • result cell types come from the column OID, not a per-value tag.
// (Full DDL-dialect rendering — SERIAL vs AUTOINCREMENT — belongs to migrations.)

public enum PostgresError: Error, CustomStringConvertible {
    case connect(String), query(String)
    public var description: String {
        switch self {
        case .connect(let m): return "postgres connect: \(m)"
        case .query(let m): return "postgres query: \(m)"
        }
    }
}

public final class PostgresDatabase: SQLDatabase, @unchecked Sendable {
    private let conn: OpaquePointer

    /// `url` is a libpq conninfo string or `postgres://…` URL.
    public init(url: String) throws {
        guard let c = PQconnectdb(url) else { throw PostgresError.connect("null connection") }
        if PQstatus(c) != CONNECTION_OK {
            let message = String(cString: PQerrorMessage(c))
            PQfinish(c)
            throw PostgresError.connect(message)
        }
        conn = c
    }

    deinit { PQfinish(conn) }

    public func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        let command = Self.translatePlaceholders(sql)

        // Bind every parameter as text (paramFormats = nil ⇒ text); libpq + the
        // server coerce by context. NULL is a nil pointer.
        let owned: [UnsafeMutablePointer<CChar>?] = parameters.map { value in
            switch value {
            case .null: return nil
            case .integer(let n): return strdup(String(n))
            case .double(let d): return strdup(String(d))
            case .text(let s): return strdup(s)
            case .blob(let b): return strdup(Self.hexLiteral(b))  // \x… bytea literal
            }
        }
        defer { for p in owned where p != nil { free(p) } }
        let params: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }

        let result = params.withUnsafeBufferPointer { buffer in
            PQexecParams(conn, command, Int32(parameters.count), nil, buffer.baseAddress, nil, nil, 0)
        }
        guard let result else { throw PostgresError.query(String(cString: PQerrorMessage(conn))) }
        defer { PQclear(result) }

        let status = PQresultStatus(result)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            throw PostgresError.query(String(cString: PQerrorMessage(conn)))
        }

        let columnCount = Int(PQnfields(result))
        var columns: [String] = []
        for c in 0..<columnCount { columns.append(String(cString: PQfname(result, Int32(c)))) }

        let rowCount = Int(PQntuples(result))
        var rows: [[SQLValue]] = []
        for r in 0..<rowCount {
            var row: [SQLValue] = []
            for c in 0..<columnCount {
                let ri = Int32(r), ci = Int32(c)
                if PQgetisnull(result, ri, ci) == 1 { row.append(.null); continue }
                let text = String(cString: PQgetvalue(result, ri, ci))
                switch PQftype(result, ci) {
                case 20, 21, 23: row.append(.integer(Int64(text) ?? 0))           // int8/int2/int4
                case 700, 701, 1700: row.append(.double(Double(text) ?? 0))       // float4/float8/numeric
                case 16: row.append(.integer(text == "t" ? 1 : 0))               // bool
                case 17: row.append(.blob(decodeByteaHex(text)))                  // bytea "\xDEADBEEF"
                default: row.append(.text(text))
                }
            }
            rows.append(row)
        }

        let affected = Int(String(cString: PQcmdTuples(result))) ?? 0
        return QueryResult(columns: columns, rows: rows, rowsAffected: affected, lastInsertID: 0)
    }

    /// Decode Postgres text-format `bytea` (`\xDEADBEEF`) into raw bytes, so a `[UInt8]`
    /// column round-trips instead of decoding to an empty array.
    private func decodeByteaHex(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        guard bytes.count >= 2, bytes[0] == 0x5C, bytes[1] == 0x78 else { return [] }   // "\x"
        func nibble(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        var i = 2
        while i + 1 < bytes.count {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { break }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// Rewrite `?` placeholders to `$1,$2,…` (naive — ignores `?` inside string
    /// literals, which the portable query builder won't emit anyway).
    static func translatePlaceholders(_ sql: String) -> String {
        var out = ""
        var n = 0
        for ch in sql {
            if ch == "?" { n += 1; out += "$\(n)" } else { out.append(ch) }
        }
        return out
    }

    private static func hexLiteral(_ bytes: [UInt8]) -> String {
        var s = "\\x"
        let digits = Array("0123456789abcdef".utf8)
        for b in bytes {
            s.unicodeScalars.append(UnicodeScalar(digits[Int(b >> 4)]))
            s.unicodeScalars.append(UnicodeScalar(digits[Int(b & 0xf)]))
        }
        return s
    }
}

/// Factory the generated composition root calls when `database = "postgres"`.
public enum PostgresDriver {
    public static func connect(url: String) throws -> Database {
        .interactiveTransactions(try PostgresDatabase(url: url), dialect: .postgres)
    }
}
