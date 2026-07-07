// Cloudflare cache adapter — the CacheStore for the Wasm target. Backed by a
// Workers KV namespace used as a cache (binding `CACHE`), with `expirationTtl`.
// Async via JSPI; two-call read for get (like KV/R2).
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

@_extern(wasm, module: "env", name: "host_cache_get")
func host_cache_get(_ ctx: Int32, _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_cache_read")
func host_cache_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

@_extern(wasm, module: "env", name: "host_cache_set")
func host_cache_set(
    _ ctx: Int32,
    _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32,
    _ valPtr: UnsafePointer<UInt8>?, _ valLen: Int32,
    _ ttlSeconds: Int32
) -> Int32

@_extern(wasm, module: "env", name: "host_cache_delete")
func host_cache_delete(_ ctx: Int32, _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32) -> Int32

struct CFCache: CacheStore {
    let ctx: Int32

    func get(_ key: String) async throws -> [UInt8]? {
        let kb = Array(key.utf8)
        let len = kb.withUnsafeBufferPointer { host_cache_get(ctx, $0.baseAddress, Int32($0.count)) }
        if len < 0 { return nil }
        if len == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(len))
        buffer.withUnsafeMutableBufferPointer { host_cache_read(ctx, $0.baseAddress) }
        return buffer
    }

    func set(_ key: String, _ value: [UInt8], ttlSeconds: Int?) async throws {
        let kb = Array(key.utf8)
        // 0 signals "no explicit expiry" across the ABI (never a real TTL).
        let ttl = Int32(ttlSeconds ?? 0)
        kb.withUnsafeBufferPointer { kp in
            value.withUnsafeBufferPointer { vp in
                _ = host_cache_set(ctx, kp.baseAddress, Int32(kp.count), vp.baseAddress, Int32(vp.count), ttl)
            }
        }
    }

    func delete(_ key: String) async throws {
        let kb = Array(key.utf8)
        _ = kb.withUnsafeBufferPointer { host_cache_delete(ctx, $0.baseAddress, Int32($0.count)) }
    }
}
#endif
