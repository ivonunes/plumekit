// Cloudflare R2 adapter — the StorageDriver for the Wasm target. Like KV but with
// delete; opaque byte payloads by key. Async via JSPI; two-call read for get.
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

@_extern(wasm, module: "env", name: "host_blob_get")
func host_blob_get(_ ctx: Int32, _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_blob_read")
func host_blob_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

@_extern(wasm, module: "env", name: "host_blob_put")
func host_blob_put(
    _ ctx: Int32,
    _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32,
    _ valPtr: UnsafePointer<UInt8>?, _ valLen: Int32
) -> Int32

@_extern(wasm, module: "env", name: "host_blob_delete")
func host_blob_delete(_ ctx: Int32, _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32) -> Int32

struct R2Storage: StorageDriver {
    let ctx: Int32

    func get(_ key: String) async throws -> [UInt8]? {
        let kb = Array(key.utf8)
        let len = kb.withUnsafeBufferPointer { host_blob_get(ctx, $0.baseAddress, Int32($0.count)) }
        if len < 0 { return nil }
        if len == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(len))
        buffer.withUnsafeMutableBufferPointer { host_blob_read(ctx, $0.baseAddress) }
        return buffer
    }

    func put(_ key: String, _ bytes: [UInt8]) async throws {
        let kb = Array(key.utf8)
        kb.withUnsafeBufferPointer { kp in
            bytes.withUnsafeBufferPointer { vp in
                _ = host_blob_put(ctx, kp.baseAddress, Int32(kp.count), vp.baseAddress, Int32(vp.count))
            }
        }
    }

    func delete(_ key: String) async throws {
        let kb = Array(key.utf8)
        _ = kb.withUnsafeBufferPointer { host_blob_delete(ctx, $0.baseAddress, Int32($0.count)) }
    }
}
#endif
