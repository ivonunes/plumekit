import CSQLite
import PlumeCore

// Native SQL adapter: SQLite via the system library. Conforms to the neutral
// `SQLDatabase`, so the same handler code runs here and against D1 on Workers.
// This is a real, embeddable database — the native reference stack needs no
// managed platform underneath.

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String)
    public var description: String {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .prepare(let m): return "sqlite prepare: \(m)"
        case .step(let m): return "sqlite step: \(m)"
        }
    }
}

// SQLite wants the destructor sentinel SQLITE_TRANSIENT (-1) so it copies bound
// text/blobs; the C macro isn't imported, so reconstruct it.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDatabase: SQLDatabase, @unchecked Sendable {
    private let handle: OpaquePointer

    /// Open a database at `path` (use `":memory:"` for an ephemeral one).
    ///
    /// FULLMUTEX: the one connection is shared across Swift-concurrency threads
    /// (requests + the channel hub's deferred SQL), and a bare sqlite3_open
    /// yields a per-connection multi-thread handle — two simultaneous queries
    /// segfault inside SQLite. The serialized mode makes the C library take its
    /// own mutex per call, which is exactly the contract this driver needs.
    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            throw SQLiteError.open(h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        handle = h
        sqlite3_busy_timeout(handle, 5000)   // writers back off instead of erroring
    }

    deinit { sqlite3_close(handle) }

    public func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in parameters.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, idx)
            case .integer(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                // Bind by explicit UTF-8 byte length, not `-1` (which stops at the first NUL
                // and would silently truncate a string containing U+0000). Empty string is
                // bound as empty text, not NULL (a nil buffer pointer would bind NULL).
                let bytes = Array(s.utf8)
                if bytes.isEmpty {
                    sqlite3_bind_text(stmt, idx, "", 0, SQLITE_TRANSIENT)
                } else {
                    _ = bytes.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                            sqlite3_bind_text(stmt, idx, $0, Int32(buf.count), SQLITE_TRANSIENT)
                        }
                    }
                }
            case .blob(let b):
                // An empty array has a nil base address, which `sqlite3_bind_blob` binds as
                // NULL; bind a zero-length blob explicitly so `[]` round-trips as an empty blob.
                if b.isEmpty {
                    sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(b.count), SQLITE_TRANSIENT) }
                }
            }
        }

        let columnCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        for c in 0..<columnCount { columns.append(String(cString: sqlite3_column_name(stmt, Int32(c)))) }

        var rows: [[SQLValue]] = []
        loop: while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                var row: [SQLValue] = []
                for c in 0..<columnCount {
                    let ci = Int32(c)
                    switch sqlite3_column_type(stmt, ci) {
                    case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(stmt, ci)))
                    case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, ci)))
                    case SQLITE_TEXT:
                        // Read by explicit byte length, not `String(cString:)` (which stops
                        // at the first NUL) — so text containing U+0000 round-trips whole.
                        if let p = sqlite3_column_text(stmt, ci) {
                            let n = Int(sqlite3_column_bytes(stmt, ci))
                            row.append(.text(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)))
                        } else {
                            row.append(.text(""))
                        }
                    case SQLITE_BLOB:
                        if let p = sqlite3_column_blob(stmt, ci) {
                            let n = Int(sqlite3_column_bytes(stmt, ci))
                            row.append(.blob([UInt8](UnsafeRawBufferPointer(start: p, count: n))))
                        } else {
                            row.append(.blob([]))
                        }
                    default: row.append(.null)
                    }
                }
                rows.append(row)
            case SQLITE_DONE: break loop
            default: throw SQLiteError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }

        return QueryResult(
            columns: columns,
            rows: rows,
            rowsAffected: Int(sqlite3_changes(handle)),
            lastInsertID: sqlite3_last_insert_rowid(handle)
        )
    }
}
