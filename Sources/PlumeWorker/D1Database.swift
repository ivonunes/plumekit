// Cloudflare D1 adapter — the SQL `Database` for the Wasm target. Conforms to the
// neutral `SQLDatabase`, so the same handler code runs against D1 here and SQLite
// natively. Async host calls suspend the wasm stack via JSPI (like KV); rows are
// marshalled across the boundary with the wire codec below (the generalisation of
// KV's byte transfer to typed, multi-column rows).
//
// The wire format MUST mirror runtime/cloudflare/worker.mjs (the SQL codec).
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

// Two-call read (like KV): the query (suspending) fetches + stashes the encoded
// result and returns its length; the read copies it into a right-sized buffer.
@_extern(wasm, module: "env", name: "host_db_query")
func host_db_query(_ ctx: Int32, _ reqPtr: UnsafePointer<UInt8>?, _ reqLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_db_read")
func host_db_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

// N statements in ONE host exchange (D1 `batch()`, atomic). Same two-call
// read protocol as host_db_query.
@_extern(wasm, module: "env", name: "host_db_batch")
func host_db_batch(_ ctx: Int32, _ reqPtr: UnsafePointer<UInt8>?, _ reqLen: Int32) -> Int32

private enum SQLValueTag {
    static let null: UInt8 = 0, integer: UInt8 = 1, double: UInt8 = 2, text: UInt8 = 3, blob: UInt8 = 4
}

func encodeQueryRequest(_ sql: String, _ parameters: [SQLValue]) -> [UInt8] {
    var w = ByteWriter()
    w.lengthPrefixedString32(sql)
    w.u16(parameters.count)
    for value in parameters {
        switch value {
        case .null: w.u8(SQLValueTag.null)
        case .integer(let n): w.u8(SQLValueTag.integer); w.i64(n)
        case .double(let d): w.u8(SQLValueTag.double); w.f64(d)
        case .text(let s): w.u8(SQLValueTag.text); w.lengthPrefixedString32(s)
        case .blob(let b): w.u8(SQLValueTag.blob); w.u32(b.count); w.raw(b)
        }
    }
    return w.bytes
}

func decodeQueryResult(_ data: [UInt8]) -> QueryResult {
    var r = ByteReader(data)
    let columnCount = r.u16() ?? 0
    var columns: [String] = []
    var c = 0
    while c < columnCount { columns.append(r.string(r.u32() ?? 0) ?? ""); c += 1 }

    let rowCount = r.u32() ?? 0
    var rows: [[SQLValue]] = []
    var ri = 0
    while ri < rowCount {
        var row: [SQLValue] = []
        var ci = 0
        while ci < columnCount {
            switch r.u8() ?? SQLValueTag.null {
            case SQLValueTag.integer: row.append(.integer(r.i64() ?? 0))
            case SQLValueTag.double: row.append(.double(r.f64() ?? 0))
            case SQLValueTag.text: row.append(.text(r.string(r.u32() ?? 0) ?? ""))
            case SQLValueTag.blob: row.append(.blob(r.take(r.u32() ?? 0) ?? []))
            default: row.append(.null)
            }
            ci += 1
        }
        rows.append(row)
        ri += 1
    }
    let affected = r.u32() ?? 0
    let lastID = r.i64() ?? 0
    return QueryResult(columns: columns, rows: rows, rowsAffected: affected, lastInsertID: lastID)
}

/// D1-backed `SQLDatabase`, bound to the in-flight request via `ctx`.
struct D1Database: SQLDatabase {
    let ctx: Int32

    func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        let request = encodeQueryRequest(sql, parameters)
        let length = request.withUnsafeBufferPointer {
            host_db_query(ctx, $0.baseAddress, Int32($0.count))
        }
        // A negative length means no DB bound OR a D1 error the host caught and logged.
        // Embedded Swift can't throw `any Error`, so we can't surface it as a catchable
        // Swift error — the query yields an empty result (the host logs the cause).
        if length < 0 {
            return QueryResult(columns: [], rows: [], rowsAffected: 0, lastInsertID: 0)
        }
        var buffer = [UInt8](repeating: 0, count: Int(length))
        if length > 0 {
            buffer.withUnsafeMutableBufferPointer { host_db_read(ctx, $0.baseAddress) }
        }
        return decodeQueryResult(buffer)
    }

    /// One host exchange for the lot — request: u16 count + u32-length-prefixed
    /// encodeQueryRequest blobs; response: u16 count + u32-length-prefixed
    /// per-statement result blobs. A host-caught D1 error yields empty results
    /// for every statement (the host logs the cause), mirroring `query`.
    func batch(_ statements: [SQLStatement]) async throws -> [QueryResult] {
        if statements.isEmpty { return [] }
        var w = ByteWriter()
        w.u16(statements.count)
        for statement in statements {
            let blob = encodeQueryRequest(statement.sql, statement.parameters)
            w.u32(blob.count)
            w.raw(blob)
        }
        let request = w.bytes
        let length = request.withUnsafeBufferPointer {
            host_db_batch(ctx, $0.baseAddress, Int32($0.count))
        }
        let empty = QueryResult(columns: [], rows: [], rowsAffected: 0, lastInsertID: 0)
        if length < 0 {
            var out: [QueryResult] = []
            for _ in statements { out.append(empty) }
            return out
        }
        var buffer = [UInt8](repeating: 0, count: Int(length))
        if length > 0 {
            buffer.withUnsafeMutableBufferPointer { host_db_read(ctx, $0.baseAddress) }
        }
        var r = ByteReader(buffer)
        let count = Int(r.u16() ?? 0)
        var out: [QueryResult] = []
        var i = 0
        while i < count {
            let blobLength = Int(r.u32() ?? 0)
            out.append(decodeQueryResult(r.take(blobLength) ?? []))
            i += 1
        }
        while out.count < statements.count { out.append(empty) }
        return out
    }
}
#endif
