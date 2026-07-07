import _Concurrency

// MARK: - The Cache capability (ephemeral, TTL'd key/value)
//
// An ephemeral cache: byte values addressed by key, each with an optional
// time-to-live after which the entry may vanish. Unlike `KV` (durable) a cache is
// best-effort — a `get` is always allowed to miss, so callers must treat nil as
// "recompute". Adapters: a native in-memory store and Cloudflare (Workers KV used
// as a cache, via `expirationTtl`). Same protocol + handle pattern as `Storage`:
// an adapter protocol and an Embedded-clean handle that wraps `some CacheStore`.

/// What a cache adapter implements (in-memory, Workers KV, Redis…). `ttlSeconds`
/// is an optional expiry; nil means "no explicit expiry". Bytes are `[UInt8]`.
public protocol CacheStore: Sendable {
    func get(_ key: String) async throws -> [UInt8]?
    func set(_ key: String, _ value: [UInt8], ttlSeconds: Int?) async throws
    func delete(_ key: String) async throws
}

/// The concrete, Embedded-clean cache handle carried in `Context`.
public struct Cache: Sendable {
    private let _get: @Sendable (String) async throws -> [UInt8]?
    private let _set: @Sendable (String, [UInt8], Int?) async throws -> Void
    private let _delete: @Sendable (String) async throws -> Void

    public init(_ adapter: some CacheStore) {
        self._get = { try await adapter.get($0) }
        self._set = { try await adapter.set($0, $1, ttlSeconds: $2) }
        self._delete = { try await adapter.delete($0) }
    }

    /// Fetch the bytes cached at `key`, or nil on a miss or expiry.
    public func get(_ key: String) async throws -> [UInt8]? { try await _get(key) }

    /// Cache `value` at `key`, optionally expiring it after `ttlSeconds`.
    public func set(_ key: String, _ value: [UInt8], ttlSeconds: Int? = nil) async throws {
        try await _set(key, value, ttlSeconds)
    }

    public func delete(_ key: String) async throws { try await _delete(key) }

    /// Fetch and UTF-8-decode the value at `key`, or nil on a miss.
    public func getString(_ key: String) async throws -> String? {
        guard let bytes = try await _get(key) else { return nil }
        return decodeUTF8(bytes)
    }

    /// UTF-8-encode and cache `value` at `key`, optionally with a TTL.
    public func setString(_ key: String, _ value: String, ttlSeconds: Int? = nil) async throws {
        try await _set(key, encodeUTF8(value), ttlSeconds)
    }
}
