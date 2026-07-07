import PlumeCore

// The Wasm worker ABI exchanges requests and responses as a compact,
// length-prefixed binary blob. Keeping it binary (rather than re-parsing HTTP
// text in JavaScript) keeps the worker glue small and the marshalling cheap.
//
// All integers are little-endian (WebAssembly linear memory is little-endian).
// This format MUST stay in lockstep with runtime/cloudflare/worker.mjs.
//
// Request:
//   u8   method code (HTTPMethod.rawValue)
//   u16  pathLen,  path bytes (UTF-8)
//   u16  queryLen, query bytes (UTF-8)
//   u16  headerCount
//     repeated: u16 nameLen, name bytes; u16 valueLen, value bytes
//   u32  bodyLen, body bytes
//
// Response:
//   u16  status
//   u16  headerCount
//     repeated: u16 nameLen, name bytes; u16 valueLen, value bytes
//   u32  bodyLen, body bytes

struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> Int? {
        guard offset + 2 <= bytes.count else { return nil }
        let v = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return v
    }

    mutating func u32() -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return Int(truncatingIfNeeded: v)
    }

    mutating func u64() -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        var u: UInt64 = 0
        for i in 0..<8 { u |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return u
    }

    mutating func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }
    mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        let slice = Array(bytes[offset..<offset + count])
        offset += count
        return slice
    }

    mutating func string(_ count: Int) -> String? {
        guard let raw = take(count) else { return nil }
        return decodeUTF8(raw)
    }
}

struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: Int) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func u32(_ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        bytes.append(UInt8(u & 0xFF))
        bytes.append(UInt8((u >> 8) & 0xFF))
        bytes.append(UInt8((u >> 16) & 0xFF))
        bytes.append(UInt8((u >> 24) & 0xFF))
    }

    mutating func u64(_ u: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((u >> (8 * i)) & 0xFF)) }
    }

    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }

    mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    mutating func lengthPrefixedString(_ s: String) {
        var b = encodeUTF8(s)
        // The length prefix is 16-bit; truncate a pathologically long value so the
        // written length always matches the bytes and the frame can't desync. (Real
        // header values are far under this; platforms cap them well below 64 KiB.)
        if b.count > 0xFFFF { b = Array(b.prefix(0xFFFF)) }
        u16(b.count)
        raw(b)
    }

    /// A 32-bit-length string — for D1, whose TEXT columns/params routinely exceed the
    /// 16-bit cap (article bodies, JSON, base64). Must pair with a u32-length reader.
    mutating func lengthPrefixedString32(_ s: String) {
        let b = encodeUTF8(s)
        u32(b.count)
        raw(b)
    }
}

/// Decode a `Request` from the wire format, or nil if the blob is malformed.
func decodeRequest(_ data: [UInt8]) -> Request? {
    var r = ByteReader(data)
    guard let code = r.u8(), let method = HTTPMethod(rawValue: code) else { return nil }
    guard let pathLen = r.u16(), let path = r.string(pathLen) else { return nil }
    guard let queryLen = r.u16(), let query = r.string(queryLen) else { return nil }
    guard let headerCount = r.u16() else { return nil }

    var headers = Headers()
    var i = 0
    while i < headerCount {
        guard let nameLen = r.u16(), let name = r.string(nameLen),
              let valueLen = r.u16(), let value = r.string(valueLen) else { return nil }
        headers.add(name, value)
        i += 1
    }

    guard let bodyLen = r.u32(), let body = r.take(bodyLen) else { return nil }
    return Request(method: method, path: path, query: query, headers: headers, body: body)
}

/// Encode a `Response` to the wire format.
func encodeResponse(_ response: Response) -> [UInt8] {
    var w = ByteWriter()
    w.u16(response.status)
    w.u16(response.headers.fields.count)
    for field in response.headers.fields {
        w.lengthPrefixedString(field.name)
        w.lengthPrefixedString(field.value)
    }
    w.u32(response.body.count)
    w.raw(response.body)
    return w.bytes
}
