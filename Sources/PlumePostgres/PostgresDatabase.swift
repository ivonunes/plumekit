#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import CPostgres
import PlumeCore

// Native Postgres SQLDatabase driver via the system libpq. Conforms to the same
// neutral `SQLDatabase` as SQLite and D1 — the proof that the abstraction takes a
// second, structurally-different SQL backend without bending.
//
// Architecture: a POOL of non-blocking connections. Every libpq exchange goes
// through the async protocol (PQsendQueryParams + socket-readiness waits), so a
// query in flight suspends its task instead of blocking a Swift-concurrency
// thread. Plain queries check a connection out per statement; a transaction pins
// one connection from BEGIN to COMMIT/ROLLBACK (via the same `TransactionContext`
// task-local the SQLite wrapper uses), so other requests keep the rest of the pool.
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

// MARK: - One non-blocking connection

/// A single libpq connection driven asynchronously. Owned by ONE task at a time —
/// the pool checks it out for a statement or pins it for a transaction — so the
/// mutable statement cache needs no lock.
final class PostgresConnection: @unchecked Sendable {
    private let conn: OpaquePointer
    /// Serial queue the readiness sources fire on.
    private let queue: DispatchQueue
    /// Server-side prepared statements are per-SESSION, so behind a
    /// transaction-mode pooler (pgbouncer default, Supabase :6543) the prepare and
    /// the execute-by-name can land on different backends — the driver must run
    /// with them off there (see `PostgresDriver.connect`).
    private let preparedStatementsEnabled: Bool

    /// Raw (untranslated) SQL → server-side prepared-statement name. Prepared once
    /// per connection, then executed by name — the parse/plan cost of the ORM's
    /// stable statements is paid once, not per call. Keyed by the raw SQL so a
    /// cache hit skips the placeholder translation too.
    private var preparedNames: [String: String] = [:]
    private var nextStatementNumber = 0
    private static let maxPreparedStatements = 64

    private init(conn: OpaquePointer, queue: DispatchQueue, preparedStatementsEnabled: Bool) {
        self.conn = conn
        self.queue = queue
        self.preparedStatementsEnabled = preparedStatementsEnabled
    }

    /// Dial asynchronously: PQconnectStart + PQconnectPoll, suspending on socket
    /// readiness — connecting never blocks a cooperative thread either.
    static func connect(url: String, preparedStatements: Bool = true) async throws -> PostgresConnection {
        guard let c = PQconnectStart(url) else { throw PostgresError.connect("null connection") }
        let queue = DispatchQueue(label: "plumekit.postgres.connection")
        if PQstatus(c) == CONNECTION_BAD {
            let message = String(cString: PQerrorMessage(c))
            PQfinish(c)
            throw PostgresError.connect(message)
        }
        polling: while true {
            switch PQconnectPoll(c) {
            case PGRES_POLLING_OK:
                break polling
            case PGRES_POLLING_READING:
                await wait(.read, socket: PQsocket(c), queue: queue)
            case PGRES_POLLING_WRITING:
                await wait(.write, socket: PQsocket(c), queue: queue)
            case PGRES_POLLING_FAILED:
                let message = String(cString: PQerrorMessage(c))
                PQfinish(c)
                throw PostgresError.connect(message)
            default:
                continue
            }
        }
        PQsetnonblocking(c, 1)
        return PostgresConnection(conn: c, queue: queue, preparedStatementsEnabled: preparedStatements)
    }

    var isHealthy: Bool { PQstatus(conn) == CONNECTION_OK && PQsocket(conn) >= 0 }

    func close() { PQfinish(conn) }

    func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        if let name = preparedNames[sql] {
            do {
                return try await execute(prepared: name, parameters)
            } catch let invalidated as PreparedStatementInvalidated {
                // Schema changed under a cached plan (SQLSTATE 0A000): forget the
                // statement, free its server-side name, and retry with a fresh
                // prepare — EXCEPT inside an open transaction, which the failure
                // already aborted; retrying there would fail with 25P02 and mask
                // the real cause, so surface it and let the caller retry the
                // transaction.
                preparedNames.removeValue(forKey: sql)
                guard PQtransactionStatus(conn) == PQTRANS_IDLE else {
                    throw PostgresError.query(invalidated.message)
                }
                _ = try? await execute(direct: "DEALLOCATE \"" + name + "\"", [])
            }
        }

        let command = translatePlaceholders(sql)
        if preparedStatementsEnabled, isCacheable(command, parameters),
           preparedNames.count < Self.maxPreparedStatements {
            let name = "plume_\(nextStatementNumber)"
            nextStatementNumber += 1
            try await prepare(name: name, command: command, parameters: parameters)
            preparedNames[sql] = name
            return try await execute(prepared: name, parameters)
        }

        return try await execute(direct: command, parameters)
    }

    /// Worth a server-side prepare: the parameterised (or read) statements the ORM
    /// re-issues; transaction control and one-off DDL are sent directly. (This is a
    /// native-only target — plain String operations are fine here.)
    private func isCacheable(_ command: String, _ parameters: [SQLValue]) -> Bool {
        if !parameters.isEmpty { return true }
        return command.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .prefix(6).lowercased() == "select"
    }

    // MARK: sends

    private func prepare(name: String, command: String, parameters: [SQLValue]) async throws {
        var types = parameterTypes(parameters)
        let sent = types.withUnsafeMutableBufferPointer { buffer in
            PQsendPrepare(conn, name, command, Int32(parameters.count), buffer.baseAddress)
        }
        guard sent == 1 else { throw PostgresError.query(String(cString: PQerrorMessage(conn))) }
        try await flushOutgoing()
        _ = try await drainResults()
    }

    private func execute(prepared name: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        try withParameterBuffers(parameters) { values, lengths, formats in
            let sent = PQsendQueryPrepared(conn, name, Int32(parameters.count),
                                           values, lengths, formats, 0)
            guard sent == 1 else { throw PostgresError.query(String(cString: PQerrorMessage(conn))) }
        }
        try await flushOutgoing()
        return try await drainResults()
    }

    private func execute(direct command: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        var types = parameterTypes(parameters)
        try withParameterBuffers(parameters) { values, lengths, formats in
            let sent = types.withUnsafeMutableBufferPointer { typesBuffer in
                PQsendQueryParams(conn, command, Int32(parameters.count),
                                  typesBuffer.baseAddress, values, lengths, formats, 0)
            }
            guard sent == 1 else { throw PostgresError.query(String(cString: PQerrorMessage(conn))) }
        }
        try await flushOutgoing()
        return try await drainResults()
    }

    /// Blobs are declared `bytea` (OID 17) so they can travel in binary; everything
    /// else stays untyped (0) and the server infers from context, as before.
    private func parameterTypes(_ parameters: [SQLValue]) -> [Oid] {
        parameters.map { if case .blob = $0 { return Oid(17) } else { return Oid(0) } }
    }

    /// Marshal parameters: text format for scalars (server coerces by context),
    /// BINARY for blobs — raw bytes on the wire instead of doubled `\x…` hex.
    private func withParameterBuffers(
        _ parameters: [SQLValue],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<Int32>?, UnsafePointer<Int32>?) throws -> Void
    ) rethrows {
        var owned: [UnsafeMutablePointer<CChar>?] = []
        var lengths: [Int32] = []
        var formats: [Int32] = []
        for value in parameters {
            switch value {
            case .null:
                owned.append(nil); lengths.append(0); formats.append(0)
            case .integer(let n):
                owned.append(strdup(String(n))); lengths.append(0); formats.append(0)
            case .double(let d):
                owned.append(strdup(String(d))); lengths.append(0); formats.append(0)
            case .text(let s):
                owned.append(strdup(s)); lengths.append(0); formats.append(0)
            case .blob(let b):
                let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, b.count))
                b.withUnsafeBytes { source in
                    if b.count > 0 {
                        UnsafeMutableRawPointer(buffer).copyMemory(from: source.baseAddress!, byteCount: b.count)
                    }
                }
                owned.append(buffer); lengths.append(Int32(b.count)); formats.append(1)
            }
        }
        defer {
            for (i, pointer) in owned.enumerated() where pointer != nil {
                if formats[i] == 1 { pointer!.deallocate() } else { free(pointer) }
            }
        }
        let params: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
        try params.withUnsafeBufferPointer { valueBuffer in
            try lengths.withUnsafeBufferPointer { lengthBuffer in
                try formats.withUnsafeBufferPointer { formatBuffer in
                    try body(valueBuffer.baseAddress, lengthBuffer.baseAddress, formatBuffer.baseAddress)
                }
            }
        }
    }

    // MARK: async protocol plumbing

    private func flushOutgoing() async throws {
        while true {
            switch PQflush(conn) {
            case 0: return
            case 1: await Self.wait(.write, socket: PQsocket(conn), queue: queue)
            default: throw PostgresError.query(String(cString: PQerrorMessage(conn)))
            }
        }
    }

    /// Collect every PGresult of the exchange (the protocol requires reading until
    /// NULL even after an error) and decode the last successful one.
    private func drainResults() async throws -> QueryResult {
        var decoded: QueryResult? = nil
        var failureMessage: String? = nil
        var failureSQLState: String? = nil
        while true {
            while PQisBusy(conn) == 1 {
                await Self.wait(.read, socket: PQsocket(conn), queue: queue)
                guard PQconsumeInput(conn) == 1 else {
                    throw PostgresError.query(String(cString: PQerrorMessage(conn)))
                }
            }
            guard let result = PQgetResult(conn) else { break }
            defer { PQclear(result) }
            let status = PQresultStatus(result)
            if status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK {
                decoded = decode(result)
            } else {
                failureMessage = String(cString: PQresultErrorMessage(result))
                // PG_DIAG_SQLSTATE == 'C'
                if let field = PQresultErrorField(result, 67) {
                    failureSQLState = String(cString: field)
                }
            }
        }
        if let failureMessage {
            if let failureSQLState, failureSQLState == "0A000" {
                throw PreparedStatementInvalidated(message: failureMessage)
            }
            throw PostgresError.query(failureMessage)
        }
        return decoded ?? QueryResult(columns: [], rows: [], rowsAffected: 0, lastInsertID: 0)
    }

    private func decode(_ result: OpaquePointer) -> QueryResult {
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
                case 16: row.append(.integer(text == "t" ? 1 : 0))                // bool
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
    func translatePlaceholders(_ sql: String) -> String {
        var out = ""
        var n = 0
        for ch in sql {
            if ch == "?" { n += 1; out += "$\(n)" } else { out.append(ch) }
        }
        return out
    }

    // MARK: socket readiness

    private enum Readiness { case read, write }

    /// Suspend until the socket is readable/writable. A fresh one-shot source per
    /// wait — its cost is trivia next to the network round trip it waits for.
    private static func wait(_ readiness: Readiness, socket: Int32, queue: DispatchQueue) async {
        guard socket >= 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startReadinessSource(readiness, socket: socket, queue: queue) {
                continuation.resume()
            }
        }
    }

    private static func startReadinessSource(
        _ readiness: Readiness, socket: Int32, queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void
    ) {
        let source: DispatchSourceProtocol
        switch readiness {
        case .read: source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        case .write: source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
        }
        let guardBox = ResumeGuard()
        source.setEventHandler {
            // The serial queue orders these; fire exactly once, then tear down.
            if guardBox.resumed { return }
            guardBox.resumed = true
            source.cancel()
            fire()
        }
        source.activate()
    }
}

private final class ResumeGuard: @unchecked Sendable { var resumed = false }

/// Internal marker: a prepared statement died to a schema change (SQLSTATE 0A000,
/// "cached plan must not change result type"); the caller re-prepares and retries.
private struct PreparedStatementInvalidated: Error { let message: String }

// MARK: - Pool

/// A FIFO pool of `PostgresConnection`s. Checkout hands out an idle healthy
/// connection, dials a new one under the cap, or waits; check-in gives the
/// connection to the oldest waiter or shelves it. Unhealthy connections (a
/// dropped socket, a server restart) are discarded on either path, so the pool
/// heals itself instead of failing every query until a process restart.
actor PostgresPool {
    private let url: String
    private let maxConnections: Int
    private let preparedStatements: Bool
    private var idle: [PostgresConnection] = []
    private var openCount = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<PostgresConnection?, Never>)] = []
    private var nextWaiterID: UInt64 = 0

    init(url: String, maxConnections: Int, preparedStatements: Bool = true) {
        self.url = url
        self.maxConnections = max(1, maxConnections)
        self.preparedStatements = preparedStatements
    }

    func checkout() async throws -> PostgresConnection {
        while true {
            // A cancelled request must not keep queueing for (and then consume) a
            // connection it no longer wants.
            try Task.checkCancellation()
            while let conn = idle.popLast() {
                if conn.isHealthy { return conn }
                conn.close()
                openCount -= 1
            }
            if openCount < maxConnections {
                openCount += 1
                do {
                    return try await PostgresConnection.connect(url: url,
                                                                preparedStatements: preparedStatements)
                } catch {
                    openCount -= 1
                    // Capacity freed — let one waiter retry (it may create anew).
                    resumeOneWaiter(with: nil)
                    throw error
                }
            }
            let id = nextWaiterID
            nextWaiterID += 1
            let handed: PostgresConnection? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiters.append((id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
            if Task.isCancelled {
                // A hand-off can race the cancellation — pass it on, don't strand it.
                if let handed { checkin(handed) }
                throw CancellationError()
            }
            if let handed {
                if handed.isHealthy { return handed }
                handed.close()
                openCount -= 1
            }
            // nil (or unhealthy hand-off) → loop and try again.
        }
    }

    func checkin(_ conn: PostgresConnection) {
        if !conn.isHealthy {
            conn.close()
            openCount -= 1
            resumeOneWaiter(with: nil)   // capacity freed — a waiter may create anew
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: conn)
            return
        }
        idle.append(conn)
    }

    private func resumeOneWaiter(with connection: PostgresConnection?) {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume(returning: connection) }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)   // checkout sees isCancelled and throws
    }
}

// MARK: - Driver factory

/// A FIFO async mutex serialising queries on a transaction's pinned connection —
/// libpq forbids overlapping commands on one connection, and a transaction body
/// that fans out (`async let`) would otherwise interleave them.
actor PostgresQueryGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Factory the generated composition root calls when `database = "postgres"`.
public enum PostgresDriver {
    /// Build the pooled Postgres `Database`. `url` is a libpq conninfo string or
    /// `postgres://…` URL. Pool size comes from `poolSize`, overridable at deploy
    /// time with the `DATABASE_POOL_SIZE` environment variable. Connections are
    /// dialled lazily on first use (and re-dialled if they die).
    ///
    /// `preparedStatements` (or `DATABASE_PREPARED_STATEMENTS=off` in the
    /// environment) turns off server-side statement caching — required behind a
    /// TRANSACTION-mode pooler (pgbouncer's default, Supabase's pooler on :6543),
    /// where prepare and execute can land on different backend sessions.
    public static func connect(url: String, poolSize: Int = 8,
                               preparedStatements: Bool = true) throws -> Database {
        let configured = environmentPoolSize() ?? poolSize
        let preparedEnabled = environmentPreparedStatements() ?? preparedStatements
        let pool = PostgresPool(url: url, maxConnections: configured,
                                preparedStatements: preparedEnabled)

        @Sendable func pinnedHandle(_ conn: PostgresConnection, _ gate: PostgresQueryGate) -> Database {
            Database(query: { sql, parameters in
                         await gate.acquire()
                         do {
                             let result = try await conn.query(sql, parameters)
                             await gate.release()
                             return result
                         } catch {
                             await gate.release()
                             throw error
                         }
                     },
                     dialect: .postgres,
                     transaction: { body in try await body(pinnedHandle(conn, gate)) })
        }

        return Database(
            query: { sql, parameters in
                // Inside a transaction on this task, route to its pinned connection
                // (`db.query` in a transaction body must not grab a second one).
                if let tx = TransactionContext.database {
                    return try await tx.query(sql, parameters)
                }
                let conn = try await pool.checkout()
                do {
                    let result = try await conn.query(sql, parameters)
                    await pool.checkin(conn)
                    return result
                } catch {
                    await pool.checkin(conn)   // discards it if the socket died
                    throw error
                }
            },
            dialect: .postgres,
            transaction: { body in
                if let joined = TransactionContext.database {
                    try await body(joined)
                    return
                }
                let conn = try await pool.checkout()
                let gate = PostgresQueryGate()
                let tx = pinnedHandle(conn, gate)
                do {
                    _ = try await tx.query("BEGIN", [])
                    try await TransactionContext.$database.withValue(tx) {
                        try await body(tx)
                    }
                    _ = try await tx.query("COMMIT", [])
                    await pool.checkin(conn)
                } catch {
                    _ = try? await tx.query("ROLLBACK", [])
                    await pool.checkin(conn)
                    throw error
                }
            })
    }

    private static func environmentPoolSize() -> Int? {
        guard let raw = getenv("DATABASE_POOL_SIZE") else { return nil }
        return Int(String(cString: raw))
    }

    private static func environmentPreparedStatements() -> Bool? {
        guard let raw = getenv("DATABASE_PREPARED_STATEMENTS") else { return nil }
        switch String(cString: raw).lowercased() {
        case "off", "false", "0", "no": return false
        case "on", "true", "1", "yes": return true
        default: return nil
        }
    }
}
