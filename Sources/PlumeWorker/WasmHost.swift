// The wasm side of the host-binding bridge. Compiled only for wasm (it declares
// custom `env` imports and drives Swift Concurrency on the WASI cooperative
// executor); excluded entirely on native builds.
//
// How the async bridge works (see also runtime/cloudflare/worker.mjs):
//   • Async host imports (KV) have a *synchronous* wasm signature. JS wraps them
//     with `WebAssembly.Suspending`, so calling one suspends the entire wasm
//     stack (JSPI) until the JS promise resolves, then resumes — transparently.
//   • The guest entry `plumekit_handle` is wrapped by JS with
//     `WebAssembly.promising`, making it suspendable and promise-returning.
//   • Because host I/O suspends at the wasm level, the Swift handler never truly
//     blocks the executor: we just run the handler Task and drain the WASI
//     cooperative executor with `runUntil { done }`.
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore
import PlumeORM

// MARK: - Host imports (custom `env` module — NOT WASI)

@_extern(wasm, module: "env", name: "host_log")
func host_log(_ ptr: UnsafePointer<UInt8>?, _ len: Int32)

@_extern(wasm, module: "env", name: "host_now")
func host_now() -> Double   // epoch milliseconds (JS Date.now())

@_extern(wasm, module: "env", name: "host_kv_get")
func host_kv_get(_ ctx: Int32, _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_kv_read")
func host_kv_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

@_extern(wasm, module: "env", name: "host_kv_put")
func host_kv_put(
    _ ctx: Int32,
    _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32,
    _ valPtr: UnsafePointer<UInt8>?, _ valLen: Int32,
    _ ttlSeconds: Int32
) -> Int32

// Originate a broadcast to a channel's DO. Suspending (RPCs the DO), called
// from the REQUEST or QUEUE-consumer isolate where JSPI works — never the DO
// isolate. The pushes are encoded into a blob the DO decodes + fans out.
@_extern(wasm, module: "env", name: "host_broadcast")
func host_broadcast(
    _ ctx: Int32,
    _ chanPtr: UnsafePointer<UInt8>?, _ chanLen: Int32,
    _ pushesPtr: UnsafePointer<UInt8>?, _ pushesLen: Int32
) -> Int32

private func hostLog(_ message: String) {
    let bytes = Array(message.utf8)
    bytes.withUnsafeBufferPointer { host_log($0.baseAddress, Int32($0.count)) }
}

// Pushes wire: the format from PlumeCore/ChannelWire.swift
// ([u16 n]([u8 kind][u16 subjectLen][subject][u32 len][bytes])*) — the same blob
// the ChannelDO's fanOut decodes, so /broadcast RPCs and channel effects agree.
private func encodePushes(_ pushes: [ChannelPush]) -> [UInt8] {
    var writer = ChannelByteWriter()
    encodeChannelPushes(&writer, pushes)
    return writer.bytes
}

private func hostBroadcast(_ ctx: Int32, _ channel: ChannelID, _ pushes: [ChannelPush]) async {
    let chan = Array(channel.value.utf8)
    let blob = encodePushes(pushes)
    chan.withUnsafeBufferPointer { cp in
        blob.withUnsafeBufferPointer { bp in
            _ = host_broadcast(ctx, cp.baseAddress, Int32(cp.count), bp.baseAddress, Int32(bp.count))
        }
    }
}

// KV uses a two-call read: `host_kv_get` fetches the value (suspending) and
// returns its length (or -1 for "not found"); `host_kv_read` copies the cached
// bytes into a guest buffer the right size. This avoids the host re-entrantly
// calling guest exports during the suspension.
private func hostKVGet(_ ctx: Int32, _ key: String) async -> [UInt8]? {
    let keyBytes = Array(key.utf8)
    let len = keyBytes.withUnsafeBufferPointer { host_kv_get(ctx, $0.baseAddress, Int32($0.count)) }
    if len < 0 { return nil }
    if len == 0 { return [] }
    var buffer = [UInt8](repeating: 0, count: Int(len))
    buffer.withUnsafeMutableBufferPointer { host_kv_read(ctx, $0.baseAddress) }
    return buffer
}

private func hostKVPut(_ ctx: Int32, _ key: String, _ value: [UInt8], _ expiresAt: Int?) async {
    // Convert the absolute expiry to a remaining-seconds TTL here so only a small
    // duration crosses the 32-bit wire (an absolute epoch could overflow Int32).
    var ttl: Int32 = 0
    if let expiresAt {
        // Stay in Double through the subtraction so a post-2038 epoch can't trap the
        // 32-bit `Int`; the remaining duration is small and clamps safely into Int32.
        let remaining = Double(expiresAt) - host_now() / 1000
        ttl = remaining > 0 ? Int32(min(remaining, Double(Int32.max))) : 1
    }
    let keyBytes = Array(key.utf8)
    keyBytes.withUnsafeBufferPointer { kp in
        value.withUnsafeBufferPointer { vp in
            _ = host_kv_put(ctx, kp.baseAddress, Int32(kp.count), vp.baseAddress, Int32(vp.count), ttl)
        }
    }
}

/// Build the per-request `Context`, wiring KV + logging to the host imports for
/// this invocation's `ctx`. Nothing here is cached globally — `ctx` selects the
/// in-flight request's bindings on the host side.
private func makeContext(_ ctx: Int32) -> Context {
    ORMClock.now = { Int64(host_now()) }   // ORM createdAt/updatedAt source
    let kv = KV(
        get: { key in await hostKVGet(ctx, key) },
        putExpiring: { key, value, expiresAt in await hostKVPut(ctx, key, value, expiresAt) }
    )
    return Context(
        kv: kv,
        database: Database(D1Database(ctx: ctx)),
        storage: Storage(R2Storage(ctx: ctx)),
        cache: Cache(CFCache(ctx: ctx)),
        queue: Queue(CFQueue(ctx: ctx)),
        http: HTTP(CFHTTPClient(ctx: ctx)),
        secrets: Secrets(CFSecrets(ctx: ctx)),
        mailer: Mailer(CFMailer(ctx: ctx)),
        broadcaster: Broadcaster { channel, pushes in await hostBroadcast(ctx, channel, pushes) },
        log: { message in hostLog(message) }
    )
}

// MARK: - Memory ABI

/// Reserve `len` bytes in linear memory for the host to write the request into.
public func plumekitAlloc(_ len: Int32) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer.allocate(byteCount: len > 0 ? Int(len) : 1, alignment: 1)
}

/// Release a buffer handed to / returned to the host.
public func plumekitFree(_ ptr: UnsafeMutableRawPointer?, _ len: Int32) {
    ptr?.deallocate()
}

// MARK: - Driver

private final class Completion: @unchecked Sendable {
    var done = false
    var bytes: [UInt8] = []
}

/// Decode the request at `reqPtr`, run it through `app` (async) with a context
/// bound to `ctx`, and return a pointer to an 8-byte `[u32 ptr][u32 len]`
/// descriptor for the encoded response.
///
/// Driven synchronously: a handler `Task` is started and the cooperative
/// executor is drained with `runUntil`. When the handler awaits a host call,
/// JSPI suspends this whole call (including `runUntil`) and resumes it later.
public func plumekitHandle(
    _ app: Application,
    _ ctx: Int32,
    _ reqPtr: UnsafeMutableRawPointer?,
    _ reqLen: Int32
) -> UnsafeMutableRawPointer? {
    let n = reqLen > 0 ? Int(reqLen) : 0
    var data = [UInt8](repeating: 0, count: n)
    if let reqPtr, n > 0 {
        let src = reqPtr.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n { data[i] = src[i] }
    }

    let context = makeContext(ctx)
    let box = Completion()
    let task = Task { box.bytes = await processRequest(app, data, context: context); box.done = true }
    try? MainActor.executor.runUntil { box.done }
    _ = task

    let out = box.bytes
    let respLen = out.count
    let respBuf = UnsafeMutableRawPointer.allocate(byteCount: respLen > 0 ? respLen : 1, alignment: 1)
    let rb = respBuf.assumingMemoryBound(to: UInt8.self)
    for i in 0..<respLen { rb[i] = out[i] }

    let desc = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4)
    desc.storeBytes(of: UInt32(truncatingIfNeeded: UInt(bitPattern: respBuf)), toByteOffset: 0, as: UInt32.self)
    desc.storeBytes(of: UInt32(truncatingIfNeeded: respLen), toByteOffset: 4, as: UInt32.self)
    return desc
}

/// Consume ONE queue message: decode the job envelope at `msgPtr` and dispatch it
/// through `registry`, with a `Context` bound to this delivery's `ctx`. Driven
/// like `plumekitHandle` — JSPI suspends across any host calls the job's `perform`
/// makes (KV/DB/…). The JS queue handler calls this per message in the batch.
public func plumekitQueue(
    _ registry: JobRegistry,
    _ ctx: Int32,
    _ msgPtr: UnsafeMutableRawPointer?,
    _ msgLen: Int32
) {
    let n = msgLen > 0 ? Int(msgLen) : 0
    var data = [UInt8](repeating: 0, count: n)
    if let msgPtr, n > 0 {
        let src = msgPtr.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n { data[i] = src[i] }
    }

    let context = makeContext(ctx)
    let box = Completion()
    let task = Task { _ = try? await registry.dispatch(data, context); box.done = true }
    try? MainActor.executor.runUntil { box.done }
    _ = task
}
#endif
