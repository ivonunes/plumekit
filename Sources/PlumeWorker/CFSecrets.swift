// Cloudflare secrets/vars adapter — the Secrets capability for the Wasm target.
// Secrets and plain vars both live on the Worker `env` object; the host reads
// `env[name]` for this request's `ctx`.
//
// Unlike KV/D1/R2, reading `env[name]` is synchronous in JS, so the host imports
// are plain (NOT wrapped in WebAssembly.Suspending) — no JSPI suspension. The
// two-call read (get length + stash, then copy) mirrors KV to avoid the host
// re-entering guest exports.
#if arch(wasm32)
import PlumeCore

@_extern(wasm, module: "env", name: "host_secret_get")
func host_secret_get(_ ctx: Int32, _ namePtr: UnsafePointer<UInt8>?, _ nameLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_secret_read")
func host_secret_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

struct CFSecrets: SecretStore {
    let ctx: Int32
    func secret(_ name: String) async throws -> [UInt8]? {
        let nameBytes = Array(name.utf8)
        let len = nameBytes.withUnsafeBufferPointer { host_secret_get(ctx, $0.baseAddress, Int32($0.count)) }
        if len < 0 { return nil }
        if len == 0 { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(len))
        buffer.withUnsafeMutableBufferPointer { host_secret_read(ctx, $0.baseAddress) }
        return buffer
    }
}
#endif
