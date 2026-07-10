import _Concurrency

// The platform-neutral real-time channel abstraction, derived from what BOTH
// adapters needed, NOT from the Durable Object's shape. Names no platform primitive.
//
// Shape (forced by async store access being impossible in a DO):
// the adapter LOADS channel state into a synchronous store before the handler runs,
// the handler reads/writes that store + collects pushes, and the adapter APPLIES
// the effects after (persist writes, broadcast). Identical on the Cloudflare DO and
// the native long-lived actor. Embedded-clean: `[UInt8]`, byte-wise keys.

public struct ChannelID: Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A per-channel key/value snapshot the handler reads/writes synchronously. The
/// adapter pre-loads it from durable storage (DO storage / disk) and persists the
/// recorded `writes` afterwards — so state survives hibernation/restart.
///
/// Two protocol-wide key conventions the adapters enforce:
/// - **Empty value = delete** (`delete(_:)` is the named spelling): the key
///   leaves durable storage; no tombstones.
/// - **Keys starting `~` are volatile**: kept in the adapter's in-memory room
///   cache only, never billed/persisted, and lost on hibernation or restart.
///   Use them for respawnable simulation state (wandering monsters, cosmetic
///   crowds) and hot copies of records that are checkpointed durably elsewhere.
///
/// Adapters also answer a literal `"ping"` text frame with `"pong"` WITHOUT
/// dispatching the channel (Cloudflare: a hibernation auto-response that never
/// wakes the DO). Clients keep idle sockets alive with those for free; a
/// handler never sees them.
public final class ChannelStore: @unchecked Sendable {
    private var entries: [(key: String, value: [UInt8])]
    public private(set) var writes: [(key: String, value: [UInt8])] = []

    public init(_ entries: [(key: String, value: [UInt8])] = []) { self.entries = entries }

    /// The full current state (for adapters that persist the whole snapshot).
    public var snapshot: [(key: String, value: [UInt8])] { entries }

    public func get(_ key: String) -> [UInt8]? {
        for entry in entries where utf8Equal(entry.key, key) { return entry.value }
        return nil
    }
    /// Set a value — or DELETE the key by setting an empty value. The effects
    /// wire has no separate delete op, so "empty = delete" is the protocol-wide
    /// convention: the key leaves the live snapshot immediately (get → nil,
    /// list omits it) and adapters erase it from durable storage instead of
    /// persisting a tombstone that would bloat every later load.
    public func set(_ key: String, _ value: [UInt8]) {
        if value.isEmpty {
            entries.removeAll { utf8Equal($0.key, key) }
        } else {
            var found = false
            for i in 0..<entries.count where utf8Equal(entries[i].key, key) {
                entries[i].value = value; found = true; break
            }
            if !found { entries.append((key: key, value: value)) }
        }
        writes.append((key: key, value: value))
    }
    /// Delete a key (the named spelling of `set(key, [])`).
    public func delete(_ key: String) { set(key, []) }
    public func list(prefix: String) -> [(key: String, value: [UInt8])] {
        let p = Array(prefix.utf8)
        return entries.filter { channelHasPrefix(Array($0.key.utf8), p) }
    }

    // Convenience for text/int state.
    public func string(_ key: String) -> String? { get(key).map { decodeUTF8($0) } }
    public func setString(_ key: String, _ value: String) { set(key, encodeUTF8(value)) }
    public func int(_ key: String) -> Int? { string(key).flatMap { Int($0) } }
    public func setInt(_ key: String, _ value: Int) { setString(key, String(value)) }
}

/// What a subscriber prefers to receive — HTML fragments (browser) or a typed
/// payload (native/API). Pushes are tagged so the adapter delivers the matching
/// kind to each subscriber (payload-agnostic delivery, Addendum A).
public enum PayloadKind: UInt8, Sendable {
    case fragment = 0   // a Plume stream envelope / HTML
    case payload = 1    // a typed (e.g. JSON) payload
}

/// One payload-tagged push: bytes + the kind of subscriber they're for. A
/// non-empty `subject` targets ONLY subscribers whose verified token subject
/// matches (channel sessions); "" broadcasts to every subscriber of the kind.
public struct ChannelPush: Sendable {
    public let kind: PayloadKind
    public let bytes: [UInt8]
    public let subject: String
    public init(kind: PayloadKind = .fragment, bytes: [UInt8], subject: String = "") {
        self.kind = kind; self.bytes = bytes; self.subject = subject
    }
}

/// One deferred SQL write: collected by the handler, applied by the
/// adapter AFTER the handler returns and BEFORE pushes are delivered — the DB
/// analogue of store writes. Channels run with no async host access (the DO
/// isolate cannot suspend), so this is the only way a channel reaches the
/// database — and it is write-only by design.
public struct ChannelStatement: Sendable {
    public let sql: String
    public let params: [SQLValue]
    public init(_ sql: String, _ params: [SQLValue] = []) { self.sql = sql; self.params = params }
}

/// Handed to a channel handler: the loaded store + a push collector. The adapter
/// reads `pushes` afterwards and fans them out.
///
/// Also provided: the channel's `room` id (one handler type can serve many rooms),
/// `now`/`entropy` (adapter-provided wall clock + random seed — the DO isolate has
/// no suspending host calls, and injecting them keeps handlers testable), targeted
/// pushes (`push(to:)`), and deferred SQL writes (`execute`).
public final class ChannelContext: @unchecked Sendable {
    public let store: ChannelStore
    /// The room id this event belongs to ("" for legacy adapters).
    public let room: String
    /// Wall clock in epoch milliseconds at dispatch (0 for legacy adapters).
    public let now: Int64
    /// A random seed drawn by the adapter for this dispatch (0 for legacy adapters).
    public let entropy: UInt64
    public private(set) var pushes: [ChannelPush] = []
    /// Deferred SQL writes, applied by the adapter after the handler returns,
    /// in order, BEFORE any push is delivered — so anything a push tells a client
    /// to fetch is already persisted.
    public private(set) var statements: [ChannelStatement] = []
    /// Cross-channel broadcasts originated from inside this handler (origination
    /// point #3). The adapter applies them after the handler returns — native fans
    /// them into the hub; the DO RPCs each target channel's DO.
    public private(set) var broadcasts: [(channel: ChannelID, pushes: [ChannelPush])] = []

    public init(store: ChannelStore, room: String = "", now: Int64 = 0, entropy: UInt64 = 0) {
        self.store = store
        self.room = room
        self.now = now
        self.entropy = entropy
    }

    /// Push to THIS channel's subscribers (of the matching kind).
    public func push(_ bytes: [UInt8], kind: PayloadKind = .fragment) {
        pushes.append(ChannelPush(kind: kind, bytes: bytes))
    }
    /// Push ONLY to this channel's subscribers whose token subject == `subject`.
    public func push(to subject: String, _ bytes: [UInt8], kind: PayloadKind = .fragment) {
        pushes.append(ChannelPush(kind: kind, bytes: bytes, subject: subject))
    }
    public func pushFragment(_ bytes: [UInt8]) { push(bytes, kind: .fragment) }
    public func pushPayload(_ bytes: [UInt8]) { push(bytes, kind: .payload) }

    /// Queue a deferred SQL write (applied after the handler, before pushes).
    public func execute(_ sql: String, _ params: [SQLValue] = []) {
        statements.append(ChannelStatement(sql, params))
    }

    /// The room's alarm request: nil = leave as-is, a positive epoch-ms
    /// value = (re)schedule (one alarm per room — scheduling replaces), 0 =
    /// cancel. The adapter applies it after the handler (DO `setAlarm`; native
    /// timer task). When it fires, the handler receives `ChannelEvent.alarm`.
    public private(set) var alarmRequest: Int64? = nil

    /// (Re)schedule this room's alarm for `atMs` (epoch milliseconds).
    public func scheduleAlarm(atMs: Int64) { alarmRequest = atMs > 0 ? atMs : 0 }
    /// Cancel this room's alarm.
    public func cancelAlarm() { alarmRequest = 0 }

    /// Originate a broadcast to ANOTHER channel from inside this handler.
    public func broadcast(to channel: ChannelID, _ pushes: [ChannelPush]) {
        broadcasts.append((channel: channel, pushes: pushes))
    }
}

// MARK: - Broadcast origination

/// The platform-neutral way to ORIGINATE a broadcast to a channel from outside it
/// — a model change after a save, a job, or another channel handler — with NO
/// request in scope. Names no socket/DO: native pushes to the in-process hub;
/// Cloudflare RPCs the channel's Durable Object (the request/queue isolate where
/// JSPI works). The model layer expresses intent; this is the only seam it touches.
public struct Broadcaster: Sendable {
    private let _send: @Sendable (ChannelID, [ChannelPush]) async -> Void
    public init(_ send: @escaping @Sendable (ChannelID, [ChannelPush]) async -> Void) { self._send = send }
    public func send(to channel: ChannelID, _ pushes: [ChannelPush]) async {
        await _send(channel, pushes)
    }
}

/// A model whose changes broadcast to a channel. The app declares the target
/// channel id (resolved from the model) and the pushes (fragment(s) rendered with
/// no request + a typed payload) — naming no socket or platform type.
public protocol Broadcastable {
    static func broadcastChannel(for model: Self) -> ChannelID
    static func broadcastPushes(for model: Self) -> [ChannelPush]
}

/// Fan a model change out to its channel — fragment for web, typed for native.
/// Works with no request in scope (from a save, a job, or a channel handler).
public func broadcast<M: Broadcastable>(_ model: M, via broadcaster: Broadcaster) async {
    await broadcaster.send(to: M.broadcastChannel(for: model), M.broadcastPushes(for: model))
}

/// A connection-lifecycle event. `subject` is the verified token
/// subject of the socket that produced the event — the channel's authenticated
/// sender identity. When subscriptions are unsigned (no signing key configured —
/// dev mode), the subject is whatever the client presented, unverified.
public enum ChannelEvent: Sendable {
    case open(subject: String)
    case message(subject: String, bytes: [UInt8])
    case close(subject: String)
    /// The room's scheduled alarm fired. No subject — alarms belong to the
    /// room, not a socket.
    case alarm
}

/// A channel: app code names no platform type. The adapter (DO or native actor)
/// shards by id, loads state, runs the handler, and applies the effects.
///
/// Implement `onMessage` for broadcast-style channels, or `onEvent` when
/// the channel needs sender identity and connect/disconnect lifecycle — the
/// default `onEvent` forwards `.message` to `onMessage` and ignores open/close,
/// so existing channels are unaffected.
public protocol Channel: Sendable {
    init()
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws
    func onEvent(_ event: ChannelEvent, _ context: ChannelContext) async throws
}

extension Channel {
    public func onEvent(_ event: ChannelEvent, _ context: ChannelContext) async throws {
        if case .message(_, let bytes) = event {
            try await onMessage(bytes, context)
        }
    }
}

func channelHasPrefix(_ a: [UInt8], _ p: [UInt8]) -> Bool {
    if a.count < p.count { return false }
    for i in 0..<p.count where a[i] != p[i] { return false }
    return true
}

// MARK: - Signed subscriptions

/// A signed, channel-scoped subscription token. Broadcasting makes channel
/// authorization a real attack surface: a client must not subscribe to an arbitrary
/// channel and receive another entity's broadcasts. The server mints a token bound
/// to a specific channel id (+ subject + expiry) with the configured signing secret; the
/// channel verifies it at subscribe and rejects unsigned/forged/expired/mismatched
/// tokens with a timing-safe comparison.
///
/// The channel is NOT carried in the token string — it's folded into the signed
/// message, so a token minted for channel A fails to verify against channel B.
/// Wire: `hex(subject) "." expirySeconds "." hex(hmac)` — all ASCII, byte-wise.
public enum ChannelToken {
    private static func signedMessage(_ channel: ChannelID, _ subject: String, _ expiry: Int) -> [UInt8] {
        var message = Array(channel.value.utf8)
        message.append(0x1F)                       // unit separator
        message.append(contentsOf: Array(subject.utf8))
        message.append(0x1F)
        message.append(contentsOf: Array(String(expiry).utf8))
        return message
    }

    /// Mint a token scoping `subject` to `channel` until `expiresAt` (epoch seconds).
    public static func mint(channel: ChannelID, subject: String, expiresAt: Int, key: [UInt8]) -> String {
        let sig = hmacSHA256(key: key, message: signedMessage(channel, subject, expiresAt))
        return hexEncode(Array(subject.utf8)) + "." + String(expiresAt) + "." + hexEncode(sig)
    }

    /// Extract the (UNVERIFIED) subject a token carries. Adapters call this only
    /// after `verify` succeeds — or, when no signing key is configured (dev mode),
    /// to adopt the client-presented subject as-is.
    public static func subject(_ token: String) -> String? {
        let parts = splitOnByte(Array(token.utf8), 0x2E)   // '.'
        guard parts.count == 3, let subjectBytes = hexDecode(parts[0]) else { return nil }
        return decodeUTF8(subjectBytes)
    }

    /// Verify a token for `channel` at time `now` (epoch seconds). Rejects malformed,
    /// expired, wrong-channel, and forged tokens; the signature check is timing-safe.
    public static func verify(_ token: String, channel: ChannelID, now: Int, key: [UInt8]) -> Bool {
        let parts = splitOnByte(Array(token.utf8), 0x2E)   // '.'
        guard parts.count == 3 else { return false }
        guard let subjectBytes = hexDecode(parts[0]) else { return false }
        guard let expiry = Int(decodeUTF8(parts[1])) else { return false }
        guard let sig = hexDecode(parts[2]) else { return false }
        if now > expiry { return false }                   // expired
        let subject = decodeUTF8(subjectBytes)
        let expected = hmacSHA256(key: key, message: signedMessage(channel, subject, expiry))
        return constantTimeEqual(sig, expected)
    }
}
