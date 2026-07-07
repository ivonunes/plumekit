// The channel event/effects wire format, shared by every adapter side that
// speaks it in Swift: the wasm guest (PlumeWorker/ChannelHost) encodes/decodes it
// at the DO boundary, and the native tests round-trip it. The JS mirror lives in
// runtime/cloudflare/worker.mjs (ChannelDO) — keep them in lockstep.
//
// All integers little-endian. Embedded-clean: bytes only, no Foundation.
//
// Event meta (host → guest, alongside the state snapshot + message bytes):
//   u8   event kind (0 = open, 1 = message, 2 = close, 3 = alarm)
//   u16  roomLen,    room bytes (UTF-8)
//   u16  subjectLen, subject bytes (UTF-8)
//   u64  now (epoch milliseconds)
//   u64  entropy (adapter-drawn random seed)
//
// Effects (guest → host):
//   u16  writeCount     repeated: u16 keyLen, key; u32 valLen, val
//   u16  stmtCount      repeated: u32 sqlLen, sql; u16 paramCount, params
//   u16  pushCount      repeated: push
//   u16  broadcastCount repeated: u16 chanLen, chan; u16 pushCount, pushes
//   u8   alarmFlag (0 = leave as-is, 1 = schedule, 2 = cancel); u64 alarm atMs (when flag == 1)
//
// One push:  u8 kind; u16 subjectLen, subject ("" = broadcast); u32 len, bytes
// One param: u8 type (0 null, 1 integer, 2 double, 3 text, 4 blob); payload
//   integer/double: u64 raw bits; text/blob: u32 len, bytes

public struct ChannelEventMeta: Sendable {
    public let kind: UInt8      // 0 open, 1 message, 2 close
    public let room: String
    public let subject: String
    public let now: Int64
    public let entropy: UInt64

    public init(kind: UInt8, room: String, subject: String, now: Int64, entropy: UInt64) {
        self.kind = kind
        self.room = room
        self.subject = subject
        self.now = now
        self.entropy = entropy
    }

    public func encode() -> [UInt8] {
        var w = ChannelByteWriter()
        w.u8(kind)
        let roomBytes = Array(room.utf8)
        w.u16(roomBytes.count); w.raw(roomBytes)
        let subjectBytes = Array(subject.utf8)
        w.u16(subjectBytes.count); w.raw(subjectBytes)
        w.u64(UInt64(bitPattern: now))
        w.u64(entropy)
        return w.bytes
    }

    public static func decode(_ bytes: [UInt8]) -> ChannelEventMeta? {
        var r = ChannelByteReader(bytes)
        guard let kind = r.u8(),
              let roomLen = r.u16(), let room = r.string(roomLen),
              let subjectLen = r.u16(), let subject = r.string(subjectLen),
              let nowRaw = r.u64(), let entropy = r.u64() else { return nil }
        return ChannelEventMeta(kind: kind, room: room, subject: subject,
                                now: Int64(bitPattern: nowRaw), entropy: entropy)
    }

    /// Build the typed `ChannelEvent` this meta + message describe.
    public func event(message: [UInt8]) -> ChannelEvent {
        if kind == 0 { return .open(subject: subject) }
        if kind == 2 { return .close(subject: subject) }
        if kind == 3 { return .alarm }
        return .message(subject: subject, bytes: message)
    }
}

/// Encode the effects a handler collected (store writes → SQL statements →
/// pushes → cross-channel broadcasts — the adapter applies them in that order).
public func encodeChannelEffects(_ context: ChannelContext) -> [UInt8] {
    var w = ChannelByteWriter()
    w.u16(context.store.writes.count)
    for write in context.store.writes {
        let key = Array(write.key.utf8)
        w.u16(key.count); w.raw(key)
        w.u32(write.value.count); w.raw(write.value)
    }
    w.u16(context.statements.count)
    for stmt in context.statements {
        let sql = Array(stmt.sql.utf8)
        w.u32(sql.count); w.raw(sql)
        w.u16(stmt.params.count)
        for param in stmt.params { encodeParam(&w, param) }
    }
    encodeChannelPushes(&w, context.pushes)
    w.u16(context.broadcasts.count)
    for entry in context.broadcasts {
        let chan = Array(entry.channel.value.utf8)
        w.u16(chan.count); w.raw(chan)
        encodeChannelPushes(&w, entry.pushes)
    }
    if let alarm = context.alarmRequest, alarm > 0 {
        w.u8(1); w.u64(UInt64(bitPattern: alarm))
    } else if context.alarmRequest != nil {
        w.u8(2)
    } else {
        w.u8(0)
    }
    return w.bytes
}

/// The decoded form of `encodeChannelEffects` (used by native tests; the DO's
/// JS mirror decodes the same bytes in worker.mjs).
public struct ChannelEffects: Sendable {
    public let writes: [(key: String, value: [UInt8])]
    public let statements: [ChannelStatement]
    public let pushes: [ChannelPush]
    public let broadcasts: [(channel: String, pushes: [ChannelPush])]
    /// nil = leave the room's alarm as-is; 0 = cancel; > 0 = schedule at epoch ms.
    public let alarm: Int64?
}

public func decodeChannelEffects(_ bytes: [UInt8]) -> ChannelEffects? {
    var r = ChannelByteReader(bytes)
    guard let writeCount = r.u16() else { return nil }
    var writes: [(key: String, value: [UInt8])] = []
    for _ in 0..<writeCount {
        guard let kl = r.u16(), let key = r.string(kl),
              let vl = r.u32(), let val = r.take(vl) else { return nil }
        writes.append((key: key, value: val))
    }
    guard let stmtCount = r.u16() else { return nil }
    var statements: [ChannelStatement] = []
    for _ in 0..<stmtCount {
        guard let sl = r.u32(), let sql = r.string(sl), let paramCount = r.u16() else { return nil }
        var params: [SQLValue] = []
        for _ in 0..<paramCount {
            guard let param = decodeParam(&r) else { return nil }
            params.append(param)
        }
        statements.append(ChannelStatement(sql, params))
    }
    guard let pushes = decodeChannelPushes(&r) else { return nil }
    guard let broadcastCount = r.u16() else { return nil }
    var broadcasts: [(channel: String, pushes: [ChannelPush])] = []
    for _ in 0..<broadcastCount {
        guard let cl = r.u16(), let chan = r.string(cl),
              let chanPushes = decodeChannelPushes(&r) else { return nil }
        broadcasts.append((channel: chan, pushes: chanPushes))
    }
    var alarm: Int64? = nil
    if let flag = r.u8() {
        if flag == 1, let raw = r.u64() { alarm = Int64(bitPattern: raw) }
        else if flag == 2 { alarm = 0 }
    }
    return ChannelEffects(writes: writes, statements: statements, pushes: pushes,
                          broadcasts: broadcasts, alarm: alarm)
}

public func encodeChannelPushes(_ w: inout ChannelByteWriter, _ pushes: [ChannelPush]) {
    w.u16(pushes.count)
    for push in pushes {
        w.u8(push.kind.rawValue)
        let subject = Array(push.subject.utf8)
        w.u16(subject.count); w.raw(subject)
        w.u32(push.bytes.count); w.raw(push.bytes)
    }
}

public func decodeChannelPushes(_ r: inout ChannelByteReader) -> [ChannelPush]? {
    guard let count = r.u16() else { return nil }
    var pushes: [ChannelPush] = []
    for _ in 0..<count {
        guard let kindRaw = r.u8(), let kind = PayloadKind(rawValue: kindRaw),
              let sl = r.u16(), let subject = r.string(sl),
              let bl = r.u32(), let bytes = r.take(bl) else { return nil }
        pushes.append(ChannelPush(kind: kind, bytes: bytes, subject: subject))
    }
    return pushes
}

private func encodeParam(_ w: inout ChannelByteWriter, _ param: SQLValue) {
    switch param {
    case .null:
        w.u8(0)
    case .integer(let n):
        w.u8(1); w.u64(UInt64(bitPattern: n))
    case .double(let d):
        w.u8(2); w.u64(d.bitPattern)
    case .text(let s):
        w.u8(3)
        let bytes = Array(s.utf8)
        w.u32(bytes.count); w.raw(bytes)
    case .blob(let bytes):
        w.u8(4)
        w.u32(bytes.count); w.raw(bytes)
    }
}

private func decodeParam(_ r: inout ChannelByteReader) -> SQLValue? {
    guard let type = r.u8() else { return nil }
    switch type {
    case 0: return .null
    case 1: guard let raw = r.u64() else { return nil }; return .integer(Int64(bitPattern: raw))
    case 2: guard let raw = r.u64() else { return nil }; return .double(Double(bitPattern: raw))
    case 3: guard let len = r.u32(), let s = r.string(len) else { return nil }; return .text(s)
    case 4: guard let len = r.u32(), let bytes = r.take(len) else { return nil }; return .blob(bytes)
    default: return nil
    }
}

// MARK: - Little-endian byte reader/writer (self-contained; Embedded-clean)

public struct ChannelByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: Int) { bytes.append(UInt8(v & 0xff)); bytes.append(UInt8((v >> 8) & 0xff)) }
    public mutating func u32(_ v: Int) {
        bytes.append(UInt8(v & 0xff)); bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff)); bytes.append(UInt8((v >> 24) & 0xff))
    }
    public mutating func u64(_ v: UInt64) {
        var x = v
        for _ in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: x)); x >>= 8 }
    }
    public mutating func raw(_ data: [UInt8]) { bytes.append(contentsOf: data) }
}

public struct ChannelByteReader {
    let bytes: [UInt8]
    var offset: Int = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    public mutating func u16() -> Int? {
        guard offset + 2 <= bytes.count else { return nil }
        let v = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return v
    }
    public mutating func u32() -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return Int(truncatingIfNeeded: v)
    }
    public mutating func u64() -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return v
    }
    public mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, offset + n <= bytes.count else { return nil }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
    public mutating func string(_ n: Int) -> String? {
        take(n).map { String(decoding: $0, as: UTF8.self) }
    }
}
