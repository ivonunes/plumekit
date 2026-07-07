import _Concurrency
// MARK: - The async host-call seam
//
// `Context` is how a handler reaches per-request host capabilities (bindings and
// logging). It is the one interface the core talks to; each platform supplies a
// concrete implementation:
//
//   • Wasm/JSPI (PlumeWorker): closures call `env` host imports, suspending the
//     wasm stack across the async call via JSPI.
//   • Native (PlumeServer / console / tests): closures call an in-process store.
//
// Crucially this avoids existentials: `KV` and `Context` are concrete structs
// holding concrete (async) function values, so they remain Embedded-clean. The
// platform threads a fresh `Context` through each request — nothing here is
// cached in a global, because bindings are per-request (`env` differs per call).
//
// Future bindings (R2/D1/Queues/Secrets/…) attach here as additional fields,
// each a small struct of closures. See Bindings.swift for the seam markers.

/// A key/value binding (Workers KV / a native store).
///
/// Backed by async closures rather than `any KeyValueStore`, so it is concrete
/// and Embedded-clean. Values are `[UInt8]`, never `Data`.
public struct KV: Sendable {
    public typealias Getter = @Sendable (String) async -> [UInt8]?
    public typealias Putter = @Sendable (String, [UInt8]) async -> Void
    /// A putter that honors an absolute expiry (epoch seconds; nil = keep forever).
    public typealias ExpiringPutter = @Sendable (String, [UInt8], Int?) async -> Void

    private let _get: Getter
    private let _put: ExpiringPutter

    /// For a store with no expiry support — any `expiresAt` is ignored (kept durably).
    public init(get: @escaping Getter, put: @escaping Putter) {
        self._get = get
        self._put = { key, value, _ in await put(key, value) }
    }

    /// For a store that honors expiry (Cloudflare KV, the native file store).
    public init(get: @escaping Getter, putExpiring: @escaping ExpiringPutter) {
        self._get = get
        self._put = putExpiring
    }

    /// Fetch the bytes stored at `key`, or nil if absent (or expired).
    public func get(_ key: String) async -> [UInt8]? {
        await _get(key)
    }

    /// Store `value` at `key`. `expiresAt` (epoch seconds) auto-expires the entry —
    /// used e.g. to bound the session revocation denylist to the token's lifetime.
    public func put(_ key: String, _ value: [UInt8], expiresAt: Int? = nil) async {
        await _put(key, value, expiresAt)
    }

    /// Fetch and UTF-8-decode the value at `key`.
    public func getString(_ key: String) async -> String? {
        guard let bytes = await _get(key) else { return nil }
        return decodeUTF8(bytes)
    }

    /// UTF-8-encode and store `value` at `key`.
    public func putString(_ key: String, _ value: String, expiresAt: Int? = nil) async {
        await _put(key, encodeUTF8(value), expiresAt)
    }
}

/// Per-request host capabilities handed to handlers via `Request.context`.
public struct Context: Sendable {
    /// The KV binding for this request, or nil if none is bound.
    public let kv: KV?
    /// The SQL database binding for this request, or nil if none is bound.
    public let database: Database?
    /// The object-storage binding for this request, or nil if none is bound.
    public let storage: Storage?
    /// The ephemeral cache binding for this request, or nil if none is bound.
    public let cache: Cache?
    /// The message-queue binding for this request, or nil if none is bound.
    public let queue: Queue?
    /// The outbound HTTP client binding for this request, or nil if none is bound.
    public let http: HTTP?
    /// The secrets/config binding for this request, or nil if none is bound.
    public let secrets: Secrets?
    /// The transactional-email binding for this request, or nil if none is bound.
    public let mailer: Mailer?
    /// Originate broadcasts to a channel, or nil if none is bound.
    public let broadcaster: Broadcaster?
    /// Emit a log line (→ `console.log` on Workers, stdout natively).
    public let log: @Sendable (String) -> Void

    public init(
        kv: KV? = nil,
        database: Database? = nil,
        storage: Storage? = nil,
        cache: Cache? = nil,
        queue: Queue? = nil,
        http: HTTP? = nil,
        secrets: Secrets? = nil,
        mailer: Mailer? = nil,
        broadcaster: Broadcaster? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.kv = kv
        self.database = database
        self.storage = storage
        self.cache = cache
        self.queue = queue
        self.http = http
        self.secrets = secrets
        self.mailer = mailer
        self.broadcaster = broadcaster
        self.log = log
    }

    /// A context with no bindings and no-op logging (used by tests / sync paths).
    public static let empty = Context()

    /// A copy of this context with a broadcaster attached. The hub/DO bridge is
    /// wired after the base context is built, so this grafts it on.
    public func adding(broadcaster: Broadcaster) -> Context {
        Context(kv: kv, database: database, storage: storage, cache: cache, queue: queue,
                http: http, secrets: secrets, mailer: mailer, broadcaster: broadcaster, log: log)
    }
}