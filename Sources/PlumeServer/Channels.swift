import Foundation
import PlumeCore

// The native channel adapter: a long-lived in-process actor
// coordinating WebSocket subscribers per channel (sharded by room id), driving an
// app-defined `Channel` handler — the SAME handler that runs in the Cloudflare
// Durable Object. Per-channel state is loaded before each event and persisted
// after (the whole snapshot to a per-room file), so it restores across a process
// restart. The native mirror of the DO; PlumeServer is native, so
// Foundation/String ops are fine here (the Unicode-linking restriction is a
// guest/wasm constraint).
//
// Channel sessions: each subscriber carries its token subject; subscribe/unsubscribe
// dispatch open/close events into the handler, messages carry the sender's
// subject, pushes can target a single subject, and handlers may queue deferred
// SQL writes that are applied to the hub's database after the handler returns
// (before pushes are delivered) — mirroring the DO adapter exactly.
public actor ChannelHub {
    private struct Subscriber {
        let kind: PayloadKind
        let subject: String
        let send: @Sendable ([UInt8]) async -> Void
    }

    private let stateDirectory: String
    private let handler: @Sendable (ChannelEvent, ChannelContext) async throws -> Void
    private let database: Database?
    private var subscribers: [String: [Int: Subscriber]] = [:]
    private var nextID = 1
    /// One pending alarm task per room — scheduling replaces, 0 cancels.
    private var alarms: [String: Task<Void, Never>] = [:]
    private var alarmGeneration: [String: Int] = [:]   // bumped on every alarm change; guards a lost-cancel fire
    /// Per-room dispatch mutex: the load→handler→save→effects sequence for a room must
    /// not interleave with another event for the SAME room across its awaits (mirroring
    /// the single-threaded Durable Object). Different rooms still run concurrently.
    private var busyRooms: Set<String> = []
    private var roomWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Legacy init: a message-only handler; open/close events are dropped.
    public init(
        stateDirectory: String,
        handler: @escaping @Sendable ([UInt8], ChannelContext) async throws -> Void
    ) {
        self.stateDirectory = stateDirectory
        self.database = nil
        self.handler = { event, context in
            if case .message(_, let bytes) = event { try await handler(bytes, context) }
        }
        try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
    }

    /// Session-aware init: a full event handler (open/message/close with sender subject) +
    /// an optional database the handler's deferred SQL writes are applied to.
    public init(
        stateDirectory: String,
        database: Database? = nil,
        events: @escaping @Sendable (ChannelEvent, ChannelContext) async throws -> Void
    ) {
        self.stateDirectory = stateDirectory
        self.database = database
        self.handler = events
        try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
    }

    /// Subscribe a socket to a room and dispatch the `.open` event for it.
    public func subscribe(
        room: String, kind: PayloadKind = .fragment, subject: String = "",
        send: @escaping @Sendable ([UInt8]) async -> Void
    ) async -> Int {
        let id = nextID
        nextID += 1
        subscribers[room, default: [:]][id] = Subscriber(kind: kind, subject: subject, send: send)
        await dispatch(room: room, event: .open(subject: subject))
        return id
    }

    /// Drop a subscriber and dispatch the `.close` event for it.
    public func unsubscribe(room: String, id: Int) async {
        guard let sub = subscribers[room]?[id] else { return }
        subscribers[room]?[id] = nil
        await dispatch(room: room, event: .close(subject: sub.subject))
    }

    public func subscriberCount(room: String) -> Int { subscribers[room]?.count ?? 0 }

    /// Handle one inbound message from a subscriber (legacy entry: subject "").
    public func handle(room: String, message: [UInt8], subject: String = "") async {
        await dispatch(room: room, event: .message(subject: subject, bytes: message))
    }

    /// Load room state → run the channel handler → persist writes → apply deferred
    /// SQL → deliver each push to matching subscribers → apply cross-channel
    /// broadcasts. The exact effect order of the DO adapter.
    private func acquireRoom(_ room: String) async {
        if !busyRooms.contains(room) { busyRooms.insert(room); return }
        await withCheckedContinuation { roomWaiters[room, default: []].append($0) }
    }

    private func releaseRoom(_ room: String) {
        if var waiters = roomWaiters[room], !waiters.isEmpty {
            let next = waiters.removeFirst()
            roomWaiters[room] = waiters.isEmpty ? nil : waiters
            next.resume()   // hand ownership to the next waiter; the room stays busy
        } else {
            busyRooms.remove(room)
        }
    }

    private func dispatch(room: String, event: ChannelEvent) async {
        await acquireRoom(room)
        let store = ChannelStore(loadRoom(room))
        let context = ChannelContext(
            store: store, room: room,
            now: Int64(Date().timeIntervalSince1970 * 1000),
            entropy: UInt64.random(in: UInt64.min...UInt64.max))
        try? await handler(event, context)
        if !store.writes.isEmpty { saveRoom(room, store.snapshot) }
        if let database {
            for stmt in context.statements {
                do { _ = try await database.query(stmt.sql, stmt.params) }
                catch { print("channel sql failed: \(stmt.sql) — \(error)") }
            }
        } else if !context.statements.isEmpty {
            print("channel sql skipped (hub has no database): \(context.statements.count) statement(s)")
        }
        for push in context.pushes { await deliver(room, push) }   // this room — the lock is held
        // The room's alarm request (nil = leave, 0 = cancel, > 0 = schedule).
        if let atMs = context.alarmRequest {
            alarms[room]?.cancel()
            alarms[room] = nil
            // Bump the generation on every change so an alarm Task that already passed its
            // `isCancelled` check (a lost cancel race) can't still fire a spurious `.alarm`
            // or clobber a newly-scheduled alarm.
            alarmGeneration[room, default: 0] += 1
            if atMs > 0 {
                let generation = alarmGeneration[room]!
                let delayMs = atMs - Int64(Date().timeIntervalSince1970 * 1000)
                alarms[room] = Task { [weak self] in
                    if delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    }
                    guard !Task.isCancelled else { return }
                    await self?.fireAlarm(room: room, generation: generation)
                }
            }
        }
        // Origination point #3: cross-channel broadcasts from inside the handler. Release
        // THIS room's lock first — those acquire the *target* room's lock, so releasing
        // before means no nested lock acquisition (no A→B / B→A deadlock, and a broadcast
        // back to this room re-acquires cleanly). Per-room delivery stays serialized.
        let crossBroadcasts = context.broadcasts
        releaseRoom(room)
        for entry in crossBroadcasts { await broadcast(entry.channel.value, entry.pushes) }
    }

    private func fireAlarm(room: String, generation: Int) async {
        // Ignore a fire from an alarm that was cancelled/replaced after it passed its
        // in-Task cancellation check (its generation is now stale).
        guard alarmGeneration[room] == generation else { return }
        alarms[room] = nil
        await dispatch(room: room, event: .alarm)
    }

    /// Originate a broadcast: fan pushes out to a channel's subscribers WITHOUT running
    /// the channel handler — used by model changes, jobs, etc. Takes the room lock so its
    /// socket writes never interleave with a concurrent `dispatch`/`broadcast` for the
    /// same room (which would garble SSE/WebSocket frames on a shared connection).
    public func broadcast(_ room: String, _ pushes: [ChannelPush]) async {
        await acquireRoom(room)
        for push in pushes { await deliver(room, push) }
        releaseRoom(room)
    }

    private func deliver(_ room: String, _ push: ChannelPush) async {
        guard let subs = subscribers[room] else { return }
        for (_, sub) in subs where sub.kind == push.kind {
            if !push.subject.isEmpty && sub.subject != push.subject { continue }
            await sub.send(push.bytes)
        }
    }

    // MARK: - Per-room state (disk-backed, restores across restart)

    private func roomPath(_ room: String) -> String {
        var safe = ""
        for scalar in room.unicodeScalars {
            let ok = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == "_"
            safe.unicodeScalars.append(ok ? scalar : "_")
        }
        return stateDirectory + "/" + safe + ".kv"
    }

    private func loadRoom(_ room: String) -> [(key: String, value: [UInt8])] {
        guard let data = FileManager.default.contents(atPath: roomPath(room)) else { return [] }
        return decodeKV([UInt8](data))
    }

    private func saveRoom(_ room: String, _ entries: [(key: String, value: [UInt8])]) {
        _ = FileManager.default.createFile(atPath: roomPath(room), contents: Data(encodeKV(entries)))
    }
}

// Length-prefixed kv: [u16 n]( [u16 keyLen][key][u32 valLen][val] )*
private func encodeKV(_ entries: [(key: String, value: [UInt8])]) -> [UInt8] {
    var out: [UInt8] = []
    func u16(_ n: Int) { out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff)) }
    func u32(_ n: Int) { out.append(UInt8((n >> 24) & 0xff)); out.append(UInt8((n >> 16) & 0xff)); out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff)) }
    u16(entries.count)
    for e in entries {
        let kb = Array(e.key.utf8)
        u16(kb.count); out.append(contentsOf: kb)
        u32(e.value.count); out.append(contentsOf: e.value)
    }
    return out
}

private func decodeKV(_ bytes: [UInt8]) -> [(key: String, value: [UInt8])] {
    var i = 0
    func u16() -> Int { let v = (Int(bytes[i]) << 8) | Int(bytes[i + 1]); i += 2; return v }
    func u32() -> Int { let v = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3]); i += 4; return v }
    guard bytes.count >= 2 else { return [] }
    let count = u16()
    var out: [(key: String, value: [UInt8])] = []
    for _ in 0..<count {
        guard i + 2 <= bytes.count else { break }
        let kl = u16(); guard i + kl <= bytes.count else { break }
        let key = String(decoding: bytes[i..<i + kl], as: UTF8.self); i += kl
        guard i + 4 <= bytes.count else { break }
        let vl = u32(); guard i + vl <= bytes.count else { break }
        let val = Array(bytes[i..<i + vl]); i += vl
        out.append((key: key, value: val))
    }
    return out
}
