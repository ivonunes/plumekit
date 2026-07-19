// The wasm side of the real-time channel bridge, the Cloudflare Durable
// Object adapter. Drives an app-defined `Channel` run-to-completion per event.
//
// JSPI suspending imports don't instantiate in a DO
// isolate, so the handler does NO async host calls. Instead the DO marshals the
// channel state in (a key/value snapshot loaded from DO storage) and applies the
// effects out (store writes + deferred SQL + pushes) — both over a byte wire
// mirrored in worker.mjs. This is the hibernation-safe model: state is always
// loaded from storage and persisted back, never trusted in guest memory.
//
// Sessions: each dispatch is an EVENT (open / message / close) carrying the
// verified token subject of the socket, plus the wall clock + a random seed the
// guest cannot obtain itself (no suspending imports in the DO). The wire formats
// live in PlumeCore/ChannelWire.swift (Swift) and worker.mjs (JS mirror).
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

private final class ChannelCompletion: @unchecked Sendable { var done = false }

/// Dispatch one channel event. `statePtr` is the encoded store snapshot the DO
/// loaded ([u16 n]([u16 keyLen][key][u32 valLen][val])*), `metaPtr` the encoded
/// `ChannelEventMeta`; returns a descriptor to the encoded effects.
public func plumekitChannelEvent(
    _ channel: some Channel,
    _ statePtr: UnsafeMutableRawPointer?, _ stateLen: Int32,
    _ metaPtr: UnsafeMutableRawPointer?, _ metaLen: Int32,
    _ msgPtr: UnsafeMutableRawPointer?, _ msgLen: Int32
) -> UnsafeMutableRawPointer? {
    let stateBytes = copyChannelBytes(statePtr, stateLen)
    let metaBytes = copyChannelBytes(metaPtr, metaLen)
    let message = copyChannelBytes(msgPtr, msgLen)

    var reader = ByteReader(stateBytes)
    var entries: [(key: String, value: [UInt8])] = []
    if let count = reader.u16() {
        for _ in 0..<count {
            guard let kl = reader.u16(), let key = reader.string(kl),
                  let vl = reader.u32(), let val = reader.take(vl) else { break }
            entries.append((key: key, value: val))
        }
    }

    let meta = ChannelEventMeta.decode(metaBytes)
        ?? ChannelEventMeta(kind: 1, room: "", subject: "", now: 0, entropy: 0)
    let context = ChannelContext(store: ChannelStore(entries), room: meta.room,
                                 now: meta.now, entropy: meta.entropy)
    let box = ChannelCompletion()
    let task = Task { try? await channel.onEvent(meta.event(message: message), context); box.done = true }
    try? MainActor.executor.runUntil { box.done }
    _ = task

    return channelDescriptor(encodeChannelEffects(context))
}

/// Signed subscriptions: verify a subscription token (sync — HMAC is pure
/// compute, no JSPI needed). The DO calls this in its WS-upgrade fetch before
/// accepting the socket. Returns 1 (valid) / 0 (rejected).
public func plumekitChannelVerify(
    _ tokenPtr: UnsafeMutableRawPointer?, _ tokenLen: Int32,
    _ chanPtr: UnsafeMutableRawPointer?, _ chanLen: Int32,
    _ keyPtr: UnsafeMutableRawPointer?, _ keyLen: Int32,
    _ now: Int32
) -> Int32 {
    let token = decodeUTF8(copyChannelBytes(tokenPtr, tokenLen))
    let channel = ChannelID(decodeUTF8(copyChannelBytes(chanPtr, chanLen)))
    let key = copyChannelBytes(keyPtr, keyLen)
    // Fail closed on an empty signing key: an empty-key HMAC is trivially forgeable
    // (anyone can reproduce it), so treat a missing key as "reject", never "accept".
    guard !key.isEmpty else { return 0 }
    return ChannelToken.verify(token, channel: channel, now: Int(now), key: key) ? 1 : 0
}

private func copyChannelBytes(_ ptr: UnsafeMutableRawPointer?, _ len: Int32) -> [UInt8] {
    let n = len > 0 ? Int(len) : 0
    guard let ptr, n > 0 else { return [] }
    return [UInt8](UnsafeRawBufferPointer(start: ptr, count: n))
}

private func channelDescriptor(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
    let length = bytes.count
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: length > 0 ? length : 1, alignment: 1)
    bytes.withUnsafeBytes { source in
        if length > 0 { buffer.copyMemory(from: source.baseAddress!, byteCount: length) }
    }
    let desc = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 4)
    desc.storeBytes(of: UInt32(truncatingIfNeeded: UInt(bitPattern: buffer)), toByteOffset: 0, as: UInt32.self)
    desc.storeBytes(of: UInt32(truncatingIfNeeded: length), toByteOffset: 4, as: UInt32.self)
    return desc
}
#endif
