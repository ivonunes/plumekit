import Foundation
import PlumeCore

// Native implementations of the KV binding, so the *same* async handler code
// runs under `plumekit serve` / `plumekit console` / tests as on Workers — just
// against an in-process store instead of the JSPI bridge.

/// A directory-backed KV store (one file per key). Persists across processes so
/// `serve` and `console` share data. An actor for safe concurrent access.
actor FileKVStore {
    private let directory: String

    init(directory: String) {
        self.directory = directory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func path(for key: String) -> String {
        directory + "/" + safeStoreFilename(key)
    }

    // Expiry lives in a sidecar (`<key>.exp`, epoch seconds) so value files stay
    // byte-identical for non-expiring keys.
    private func expiryPath(for key: String) -> String { path(for: key) + ".exp" }

    func get(_ key: String) -> [UInt8]? {
        if let expData = FileManager.default.contents(atPath: expiryPath(for: key)),
           let expiresAt = Int(String(decoding: expData, as: UTF8.self)),
           Int(Date().timeIntervalSince1970) >= expiresAt {
            try? FileManager.default.removeItem(atPath: path(for: key))     // lazily evict
            try? FileManager.default.removeItem(atPath: expiryPath(for: key))
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path(for: key)) else { return nil }
        return [UInt8](data)
    }

    func put(_ key: String, _ value: [UInt8], expiresAt: Int?) {
        _ = FileManager.default.createFile(atPath: path(for: key), contents: Data(value))
        if let expiresAt {
            _ = FileManager.default.createFile(atPath: expiryPath(for: key), contents: Data(String(expiresAt).utf8))
        } else {
            try? FileManager.default.removeItem(atPath: expiryPath(for: key))
        }
    }
}

/// An in-memory KV store (for tests). An actor for genuine async semantics.
actor MemoryKVStore {
    private var data: [String: (value: [UInt8], expiresAt: Int?)] = [:]
    func get(_ key: String) -> [UInt8]? {
        guard let entry = data[key] else { return nil }
        if let expiresAt = entry.expiresAt, Int(Date().timeIntervalSince1970) >= expiresAt {
            data[key] = nil
            return nil
        }
        return entry.value
    }
    func put(_ key: String, _ value: [UInt8], expiresAt: Int?) { data[key] = (value, expiresAt) }
}

public enum NativeKV {
    /// A `Context` backed by a directory store, logging to stdout. Used by
    /// `plumekit serve` and `plumekit console`.
    public static func fileContext(directory: String) -> Context {
        let store = FileKVStore(directory: directory)
        let kv = KV(
            get: { key in await store.get(key) },
            putExpiring: { key, value, expiresAt in await store.put(key, value, expiresAt: expiresAt) }
        )
        return Context(kv: kv, log: { message in print(message) })
    }

    /// A `Context` backed by an in-memory store, with no-op logging. Used by tests.
    public static func memoryContext() -> Context {
        let store = MemoryKVStore()
        let kv = KV(
            get: { key in await store.get(key) },
            putExpiring: { key, value, expiresAt in await store.put(key, value, expiresAt: expiresAt) }
        )
        return Context(kv: kv)
    }
}
