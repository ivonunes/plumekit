// Wasm worker entry point for `plumekit build --target cloudflare`.
//
// The only place the C-ABI exports live; compiled solely for wasm (reactor
// model + JSPI), so it is guarded on arch(wasm32) and collapses to an empty main
// on a native build.
//
// `plumekit_handle` now takes a `ctx` id that routes host calls (KV, log) to the
// correct in-flight request's bindings on the JS side. The JS glue wraps this
// export with `WebAssembly.promising` so it can suspend across host calls.
//
// IMPORTANT (Embedded Swift gotchas): the app is cached in a `var = nil` global
// (reactor mode doesn't run lazy global initializers); and `import _Concurrency`
// is required wherever async is used.
#if arch(wasm32)
import PlumeCore
import PlumeWorker
import App

nonisolated(unsafe) private var app: Application? = nil
nonisolated(unsafe) private var jobs: JobRegistry? = nil

@inline(__always)
private func sharedApp() -> Application {
    if let app { return app }
    let built = buildApp()
    app = built
    return built
}

@inline(__always)
private func sharedJobs() -> JobRegistry {
    if let jobs { return jobs }
    let built = buildJobs()
    jobs = built
    return built
}

@_expose(wasm, "plumekit_alloc")
@_cdecl("plumekit_alloc")
func plumekit_alloc(_ len: Int32) -> UnsafeMutableRawPointer? {
    plumekitAlloc(len)
}

@_expose(wasm, "plumekit_free")
@_cdecl("plumekit_free")
func plumekit_free(_ ptr: UnsafeMutableRawPointer?, _ len: Int32) {
    plumekitFree(ptr, len)
}

@_expose(wasm, "plumekit_handle")
@_cdecl("plumekit_handle")
func plumekit_handle(_ ctx: Int32, _ reqPtr: UnsafeMutableRawPointer?, _ reqLen: Int32) -> UnsafeMutableRawPointer? {
    plumekitHandle(sharedApp(), ctx, reqPtr, reqLen)
}

// Queue consumer entry: workerd's queue() handler calls this once per message.
@_expose(wasm, "plumekit_queue")
@_cdecl("plumekit_queue")
func plumekit_queue(_ ctx: Int32, _ msgPtr: UnsafeMutableRawPointer?, _ msgLen: Int32) {
    plumekitQueue(sharedJobs(), ctx, msgPtr, msgLen)
}

// Durable Object channel entry: the DO passes the loaded state snapshot,
// the event meta (open/message/close + sender subject + clock/entropy), and the
// message; the app's Channel runs run-to-completion; we return the effects (store
// writes + deferred SQL + pushes) via a [ptr,len] descriptor for the DO to apply.
@_expose(wasm, "plumekit_channel_event")
@_cdecl("plumekit_channel_event")
func plumekit_channel_event(
    _ statePtr: UnsafeMutableRawPointer?, _ stateLen: Int32,
    _ metaPtr: UnsafeMutableRawPointer?, _ metaLen: Int32,
    _ msgPtr: UnsafeMutableRawPointer?, _ msgLen: Int32
) -> UnsafeMutableRawPointer? {
    plumekitChannelEvent(buildChannel(), statePtr, stateLen, metaPtr, metaLen, msgPtr, msgLen)
}

// Verify a signed subscription token at subscribe time (sync — no JSPI).
@_expose(wasm, "plumekit_channel_verify")
@_cdecl("plumekit_channel_verify")
func plumekit_channel_verify(
    _ tokenPtr: UnsafeMutableRawPointer?, _ tokenLen: Int32,
    _ chanPtr: UnsafeMutableRawPointer?, _ chanLen: Int32,
    _ keyPtr: UnsafeMutableRawPointer?, _ keyLen: Int32,
    _ now: Int32
) -> Int32 {
    plumekitChannelVerify(tokenPtr, tokenLen, chanPtr, chanLen, keyPtr, keyLen, now)
}
#endif
