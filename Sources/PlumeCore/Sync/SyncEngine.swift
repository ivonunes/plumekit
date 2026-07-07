import _Concurrency

// The apply/delta ALGORITHM for the sync primitives — generic over a `SyncStore`
// (the persistence seam), so the tricky parts (version assignment, idempotent
// dedupe, base-version conflict detection, tombstones, auth scope) live in one
// tested place. Still NOT a sync engine: it applies a single intent or returns a
// structured conflict; it never resolves a conflict.

/// Persistence seam for syncable records. An adapter (SQL over a Syncable model, or
/// an in-memory test double) implements it; the engine wraps it in closures so no
/// existential is stored (Embedded-clean).
public protocol SyncStore: Sendable {
    func recordByUID(_ uid: String) async throws -> SyncRecord?
    func ownerOfUID(_ uid: String) async throws -> String?
    func nextVersion() async throws -> Int64
    func upsert(uid: String, version: Int64, deleted: Bool, data: JSONValue, owner: String) async throws
    func changes(since: Int64, owner: String) async throws -> [SyncRecord]
    func appliedOutcome(_ idempotencyKey: String) async -> SyncRecord?
    func markApplied(_ idempotencyKey: String, _ record: SyncRecord) async
}

public struct SyncEngine: Sendable {
    public let schema: Int
    private let _recordByUID: @Sendable (String) async throws -> SyncRecord?
    private let _ownerOfUID: @Sendable (String) async throws -> String?
    private let _nextVersion: @Sendable () async throws -> Int64
    private let _upsert: @Sendable (String, Int64, Bool, JSONValue, String) async throws -> Void
    private let _changes: @Sendable (Int64, String) async throws -> [SyncRecord]
    private let _applied: @Sendable (String) async -> SyncRecord?
    private let _markApplied: @Sendable (String, SyncRecord) async -> Void

    public init(schema: Int, store: some SyncStore) {
        self.schema = schema
        self._recordByUID = { try await store.recordByUID($0) }
        self._ownerOfUID = { try await store.ownerOfUID($0) }
        self._nextVersion = { try await store.nextVersion() }
        self._upsert = { try await store.upsert(uid: $0, version: $1, deleted: $2, data: $3, owner: $4) }
        self._changes = { try await store.changes(since: $0, owner: $1) }
        self._applied = { await store.appliedOutcome($0) }
        self._markApplied = { await store.markApplied($0, $1) }
    }

    /// (4) Delta since a cursor, scoped to `owner`: changed records + tombstones, and
    /// the new cursor (the max version seen, or the prior cursor if nothing changed).
    public func delta(since: Int64, owner: String) async throws -> (changes: [SyncRecord], cursor: Int64) {
        let changes = try await _changes(since, owner)
        var cursor = since
        for record in changes where record.version > cursor { cursor = record.version }
        return (changes, cursor)
    }

    /// Apply one mutation intent, returning a structured outcome.
    public func apply(_ intent: MutationIntent, owner: String) async throws -> MutationOutcome {
        // (7) data schema version must match.
        if intent.schema != schema { return .schemaMismatch(expected: schema, got: intent.schema) }
        // (5) idempotent replay — return the prior outcome, don't apply twice.
        if let prior = await _applied(intent.idempotencyKey) { return .deduped(prior) }

        let existing = try await _recordByUID(intent.uid)

        if utf8Equal(intent.op, "create") {   // byte-wise — runs in the guest
            if let existing { return .conflict(current: existing, attempted: intent) }   // uid already exists
            let version = try await _nextVersion()
            let record = SyncRecord(uid: intent.uid, version: version, deleted: false,
                                    schema: schema, data: intent.data)
            try await _upsert(intent.uid, version, false, intent.data, owner)   // (8) owned by the creator
            await _markApplied(intent.idempotencyKey, record)
            return .applied(record)
        }

        // update / delete
        guard let existing else {
            return .conflict(current: SyncRecord.gone(intent.uid, schema: schema), attempted: intent)
        }
        // (8) sync scope is authorization-bounded — only the owner may mutate.
        if let recordOwner = try await _ownerOfUID(intent.uid), !utf8Equal(recordOwner, owner) {
            return .unauthorized
        }
        // (2)+(6) base-version conflict.
        if existing.version != intent.baseVersion {
            return .conflict(current: existing, attempted: intent)
        }
        let version = try await _nextVersion()
        let deleted = utf8Equal(intent.op, "delete")                           // (3) tombstone
        let data: JSONValue = deleted ? .object([]) : intent.data
        let record = SyncRecord(uid: intent.uid, version: version, deleted: deleted, schema: schema, data: data)
        try await _upsert(intent.uid, version, deleted, data, owner)
        await _markApplied(intent.idempotencyKey, record)
        return .applied(record)
    }
}
