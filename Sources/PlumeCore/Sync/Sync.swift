import _Concurrency

// Sync-readiness PRIMITIVES — the protocol-level pieces a future offline/sync
// engine needs, included up front because they would be protocol-breaking to
// add later. This is NOT a sync engine: no client store, no write queue, no conflict
// RESOLUTION policy — only the wire shapes + the minimal server hooks. All
// reflection-free JSON (no new serializer) and Embedded-clean.

/// A synced record on the wire. Carries the four sync primitives every payload needs.
public struct SyncRecord: Sendable {
    public let uid: String       // (1) stable, client-mintable global id
    public let version: Int64    // (2) server-assigned monotonic change version
    public let deleted: Bool     // (3) tombstone — a delete is data, not absence
    public let schema: Int       // (7) data schema version
    public let data: JSONValue   // allow-list-serialized fields (empty for a tombstone)

    public init(uid: String, version: Int64, deleted: Bool, schema: Int, data: JSONValue) {
        self.uid = uid; self.version = version; self.deleted = deleted; self.schema = schema; self.data = data
    }

    public func json() -> JSONValue {
        .object([
            ("uid", .string(uid)),
            ("version", .int(version)),
            ("deleted", .bool(deleted)),
            ("schema", .int(Int64(schema))),
            ("data", data),
        ])
    }

    public static func parse(_ json: JSONValue?) -> SyncRecord? {
        guard let json, let uid = json["uid"]?.stringValue, let version = json["version"]?.intValue else {
            return nil
        }
        return SyncRecord(uid: uid, version: version,
                          deleted: json["deleted"]?.boolValue ?? false,
                          schema: Int(json["schema"]?.intValue ?? 0),
                          data: json["data"] ?? .object([]))
    }

    /// A tombstone for a uid the client thinks exists but the server doesn't (gone).
    public static func gone(_ uid: String, schema: Int) -> SyncRecord {
        SyncRecord(uid: uid, version: 0, deleted: true, schema: schema, data: .object([]))
    }
}

/// (4) Delta / since-cursor catch-up response: changed records + tombstones since a
/// cursor, plus the new cursor to pass next time.
public func deltaJSON(_ changes: [SyncRecord], cursor: Int64, schema: Int) -> JSONValue {
    .object([
        ("changes", .array(changes.map { $0.json() })),
        ("cursor", .int(cursor)),
        ("schema", .int(Int64(schema))),
    ])
}

/// (5) An idempotent, version-based mutation intent from a client. `idempotencyKey`
/// dedupes replays (the same idempotency rule as jobs); `baseVersion` is the version the change
/// was made against (0 for a create) so the server can apply-or-reject-as-conflict.
public struct MutationIntent: Sendable {
    public let idempotencyKey: String
    public let baseVersion: Int64
    public let op: String        // "create" | "update" | "delete"
    public let uid: String       // client-minted
    public let schema: Int
    public let data: JSONValue

    public init(idempotencyKey: String, baseVersion: Int64, op: String, uid: String, schema: Int, data: JSONValue) {
        self.idempotencyKey = idempotencyKey; self.baseVersion = baseVersion
        self.op = op; self.uid = uid; self.schema = schema; self.data = data
    }

    public static func parse(_ json: JSONValue?) -> MutationIntent? {
        guard let json,
              let key = json["idempotencyKey"]?.stringValue,
              let op = json["op"]?.stringValue,
              let uid = json["uid"]?.stringValue else { return nil }
        return MutationIntent(
            idempotencyKey: key,
            baseVersion: json["baseVersion"]?.intValue ?? 0,
            op: op, uid: uid,
            schema: Int(json["schema"]?.intValue ?? 0),
            data: json["data"] ?? .object([]))
    }

    func attemptedJSON() -> JSONValue {
        .object([
            ("op", .string(op)), ("uid", .string(uid)),
            ("baseVersion", .int(baseVersion)), ("data", data),
        ])
    }
}

/// (6) The outcome of applying an intent — a conflict is a FIRST-CLASS response
/// (current server state + the client's attempt), giving a future resolution layer
/// what it needs. This carries the conflict; it does NOT resolve it.
public enum MutationOutcome: Sendable {
    case applied(SyncRecord)
    case deduped(SyncRecord)                                  // idempotent replay
    case conflict(current: SyncRecord, attempted: MutationIntent)
    case schemaMismatch(expected: Int, got: Int)             // (7)
    case unauthorized                                        // (8)

    public func response() -> Response {
        switch self {
        case .applied(let record):
            return .json(.object([("result", .string("applied")), ("record", record.json())]))
        case .deduped(let record):
            return .json(.object([("result", .string("deduped")), ("record", record.json())]))
        case .conflict(let current, let attempted):
            return .json(.object([
                ("result", .string("conflict")),
                ("current", current.json()),
                ("attempted", attempted.attemptedJSON()),
            ]), status: 409)
        case .schemaMismatch(let expected, let got):
            return APIError(status: 422, code: "schema_mismatch",
                            message: "data schema \(got) does not match server schema \(expected)").response()
        case .unauthorized:
            return APIError(status: 403, code: "forbidden",
                            message: "outside your sync scope").response()
        }
    }
}
