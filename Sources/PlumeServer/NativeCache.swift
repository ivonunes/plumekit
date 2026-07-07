import Foundation
import PlumeCore

// The native Cache adapter, so the *same* handler code runs under `plumekit serve`
// / `plumekit console` / tests as on Workers — just against an in-process store
// instead of the JSPI bridge. Ephemeral by design: entries live only for this
// process and are dropped once their TTL elapses.

/// An in-memory cache with per-key expiry. An actor for safe concurrent access.
public actor MemoryCache: CacheStore {
    private struct Entry { let value: [UInt8]; let expiresAtMillis: Int64? }
    private var store: [String: Entry] = [:]

    public init() {}

    public func get(_ key: String) -> [UInt8]? {
        guard let entry = store[key] else { return nil }
        if let expiry = entry.expiresAtMillis, nowMillis() >= expiry {
            store[key] = nil        // lazily evict on read
            return nil
        }
        return entry.value
    }

    public func set(_ key: String, _ value: [UInt8], ttlSeconds: Int?) {
        let expiry = ttlSeconds.map { nowMillis() + Int64($0) * 1000 }
        store[key] = Entry(value: value, expiresAtMillis: expiry)
    }

    public func delete(_ key: String) { store[key] = nil }

    private func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
