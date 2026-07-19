/// Byte / string helpers used across the core.
///
/// Everything here works on `[UInt8]` and the stdlib's UTF-8 facilities so it
/// stays Embedded-clean (no Foundation, no `Data`).

/// Decode UTF-8 bytes to a `String`, replacing invalid sequences.
@inline(__always)
public func decodeUTF8(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self)
}

@inline(__always)
public func encodeUTF8(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

/// Percent-decode `%XX` escapes in a path segment, byte-wise (no Foundation
/// `removingPercentEncoding`, which doesn't link under Embedded). `+` is left as a
/// literal `+` — path segments are not form-encoded.
public func percentDecodePath(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x25, i + 2 < bytes.count,
           let hi = hexNibble(bytes[i + 1]), let lo = hexNibble(bytes[i + 2]) {
            out.append(UInt8(hi << 4 | lo)); i += 3
        } else {
            out.append(bytes[i]); i += 1
        }
    }
    return out
}

private func hexNibble(_ byte: UInt8) -> Int? {
    switch byte {
    case 0x30...0x39: return Int(byte - 0x30)
    case 0x41...0x46: return Int(byte - 0x41 + 10)
    case 0x61...0x66: return Int(byte - 0x61 + 10)
    default: return nil
    }
}

/// Byte-wise `<` between strings (no Unicode `String <`, which doesn't link under
/// Embedded). Sorts locale tags, migration versions, translation keys.
public func asciiLess(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var i = 0
    while i < x.count, i < y.count {
        if x[i] != y[i] { return x[i] < y[i] }
        i += 1
    }
    return x.count < y.count
}

/// Percent-encode bytes (RFC 3986 unreserved set kept verbatim), byte-wise. The
/// one encoder behind multipart round-tripping and the test client's form
/// encoding — the decode side is `FormParams`, which accepts `%XX` and `+` alike.
public func percentEncode(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    let hex = Array("0123456789ABCDEF".utf8)
    for b in bytes {
        let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
        if unreserved { out.append(b) }
        else { out.append(0x25); out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)]) }
    }
    return out
}

/// Split a byte buffer on a separator byte (no `String.split`; it doesn't link under Embedded).
public func splitOnByte(_ bytes: [UInt8], _ separator: UInt8) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var current: [UInt8] = []
    for b in bytes {
        if b == separator { out.append(current); current = [] } else { current.append(b) }
    }
    out.append(current)
    return out
}

/// Exact (case-sensitive) UTF-8 byte equality of two strings.
///
/// Swift's `String == ` (and `hasPrefix`/`contains`/`.count`/`switch`-over-`String`) iterate
/// grapheme clusters / use Unicode canonical-equivalence, which drag in normalization + grapheme
/// data tables that are **unavailable when linking for embedded wasm** — code compiles natively
/// and only fails at `wasm-ld` with `undefined symbol: _swift_stdlib_getGraphemeBreakProperty`.
/// Comparing the UTF-8 views byte-for-byte avoids that entirely, and is
/// the right comparison for wire-level tokens (paths, header/param names) and ASCII app state.
///
/// **Guest apps should use these instead of `String ==`/`hasPrefix`/`contains`.**
@inline(__always)
public func utf8Equal(_ a: String, _ b: String) -> Bool {
    let au = a.utf8
    let bu = b.utf8
    if au.count != bu.count { return false }
    var ai = au.makeIterator()
    var bi = bu.makeIterator()
    while let x = ai.next(), let y = bi.next() {
        if x != y { return false }
    }
    return true
}

/// Byte-wise prefix test (embedded-safe replacement for `String.hasPrefix`).
@inline(__always)
public func utf8HasPrefix(_ s: String, _ prefix: String) -> Bool {
    let a = Array(s.utf8), p = Array(prefix.utf8)
    if p.count > a.count { return false }
    var i = 0
    while i < p.count { if a[i] != p[i] { return false }; i += 1 }
    return true
}

/// Byte-wise substring test (embedded-safe replacement for `String.contains`).
@inline(__always)
public func utf8Contains(_ s: String, _ needle: String) -> Bool {
    let a = Array(s.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    if n.count > a.count { return false }
    var i = 0
    while i <= a.count - n.count {
        var j = 0
        while j < n.count && a[i + j] == n[j] { j += 1 }
        if j == n.count { return true }
        i += 1
    }
    return false
}
