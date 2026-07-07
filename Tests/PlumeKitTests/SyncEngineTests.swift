import Testing
@testable import PlumeCore

private actor MemSync: SyncStore {
    struct Row { var version: Int64; var deleted: Bool; var data: JSONValue; var owner: String }
    var rows: [String: Row] = [:]
    var counter: Int64 = 0
    var idem: [String: SyncRecord] = [:]

    func recordByUID(_ uid: String) -> SyncRecord? {
        rows[uid].map { SyncRecord(uid: uid, version: $0.version, deleted: $0.deleted, schema: 1, data: $0.data) }
    }
    func ownerOfUID(_ uid: String) -> String? { rows[uid]?.owner }
    func nextVersion() -> Int64 { counter += 1; return counter }
    func upsert(uid: String, version: Int64, deleted: Bool, data: JSONValue, owner: String) {
        rows[uid] = Row(version: version, deleted: deleted, data: data, owner: owner)
    }
    func changes(since: Int64, owner: String) -> [SyncRecord] {
        rows.filter { $0.value.owner == owner && $0.value.version > since }
            .map { SyncRecord(uid: $0.key, version: $0.value.version, deleted: $0.value.deleted, schema: 1, data: $0.value.data) }
            .sorted { $0.version < $1.version }
    }
    func appliedOutcome(_ key: String) -> SyncRecord? { idem[key] }
    func markApplied(_ key: String, _ record: SyncRecord) { idem[key] = record }
}

private func body(_ s: String) -> JSONValue { .object([("body", .string(s))]) }
private func intent(_ key: String, _ op: String, _ uid: String, base: Int64, _ data: JSONValue, schema: Int = 1) -> MutationIntent {
    MutationIntent(idempotencyKey: key, baseVersion: base, op: op, uid: uid, schema: schema, data: data)
}

@Test func syncCreateUpdateDeleteVersionsAndDelta() async throws {
    let engine = SyncEngine(schema: 1, store: MemSync())

    // (1)(2) create — client-minted uid, server-assigned version 1
    guard case .applied(let r1) = try await engine.apply(intent("k1", "create", "note-A", base: 0, body("hello")), owner: "alice") else {
        Issue.record("create"); return
    }
    #expect(r1.version == 1 && r1.uid == "note-A" && !r1.deleted)

    // (4) delta since 0 returns it + cursor
    let d1 = try await engine.delta(since: 0, owner: "alice")
    #expect(d1.changes.count == 1 && d1.cursor == 1)

    // (2) update against base version 1 → applied, version 2
    guard case .applied(let r2) = try await engine.apply(intent("k2", "update", "note-A", base: 1, body("edited")), owner: "alice") else {
        Issue.record("update"); return
    }
    #expect(r2.version == 2)

    // (3) delete → tombstone; delta carries it
    guard case .applied(let r3) = try await engine.apply(intent("k3", "delete", "note-A", base: 2, body("")), owner: "alice") else {
        Issue.record("delete"); return
    }
    #expect(r3.deleted && r3.version == 3)
    let d2 = try await engine.delta(since: 2, owner: "alice")
    #expect(d2.changes.count == 1 && d2.changes[0].deleted)   // tombstone, not absence
}

@Test func syncStaleBaseVersionReturnsConflict() async throws {
    let engine = SyncEngine(schema: 1, store: MemSync())
    _ = try await engine.apply(intent("k1", "create", "n", base: 0, body("v1")), owner: "alice")
    _ = try await engine.apply(intent("k2", "update", "n", base: 1, body("v2")), owner: "alice")   // → version 2

    // (6) update against the now-stale base version 1
    guard case .conflict(let current, let attempted) = try await engine.apply(intent("k3", "update", "n", base: 1, body("v3")), owner: "alice") else {
        Issue.record("expected conflict"); return
    }
    #expect(current.version == 2)                 // server's current state
    #expect(attempted.baseVersion == 1)           // the client's attempt
}

@Test func syncReplayIsDeduped() async throws {
    let engine = SyncEngine(schema: 1, store: MemSync())
    let create = intent("idem-1", "create", "n", base: 0, body("hi"))
    guard case .applied(let first) = try await engine.apply(create, owner: "alice") else { Issue.record("apply"); return }
    // (5) same idempotency key → deduped, NOT applied again
    guard case .deduped(let again) = try await engine.apply(create, owner: "alice") else { Issue.record("expected deduped"); return }
    #expect(again.version == first.version)       // same record, no double-apply
}

@Test func syncSchemaMismatchAndScopeAreRejected() async throws {
    let engine = SyncEngine(schema: 2, store: MemSync())
    // (7) client carries schema 1, server is schema 2
    guard case .schemaMismatch(let expected, let got) = try await engine.apply(intent("k1", "create", "n", base: 0, body("x"), schema: 1), owner: "alice") else {
        Issue.record("expected schema mismatch"); return
    }
    #expect(expected == 2 && got == 1)

    // (8) scope: bob may not mutate alice's record
    let engine2 = SyncEngine(schema: 1, store: MemSync())
    _ = try await engine2.apply(intent("k1", "create", "n", base: 0, body("a")), owner: "alice")
    guard case .unauthorized = try await engine2.apply(intent("k2", "update", "n", base: 1, body("b")), owner: "bob") else {
        Issue.record("expected unauthorized"); return
    }
}
