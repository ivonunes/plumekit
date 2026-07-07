import PlumeRuntime
// Reflection-free JSON. Foundation's Codable/JSONEncoder use runtime
// reflection, which is forbidden under Embedded Swift, so JSON is a concrete value
// tree serialized/parsed by BYTE. Strings pass UTF-8 through (valid JSON) and only
// escape what JSON requires — no Unicode-aware String operations (those need
// Unicode tables that don't link under Embedded).
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(name: String, value: JSONValue)])   // ordered pairs, not a Dictionary

    // MARK: Reading

    public subscript(_ key: String) -> JSONValue? {
        if case .object(let pairs) = self {
            for pair in pairs where utf8Equal(pair.name, key) { return pair.value }
        }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int64? {
        switch self {
        case .int(let n): return n
        case .double(let d):
            // `Int64(d)` traps on NaN/infinity or |d| ≥ 2^63 — reachable from an
            // untrusted JSON body — so reject those instead of crashing.
            guard d.isFinite, d >= -9.223372036854776e18, d < 9.223372036854776e18 else { return nil }
            return Int64(d)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let n): return Double(n)
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    // MARK: Serializing

    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        write(into: &out)
        return out
    }

    private func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let n): out.append(contentsOf: Array(String(n).utf8))
        case .double(let d): JSONValue.writeDouble(d, into: &out)
        case .string(let s): JSONValue.writeString(s, into: &out)
        case .array(let items):
            out.append(0x5B)  // [
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(0x2C) }
                item.write(into: &out)
            }
            out.append(0x5D)  // ]
        case .object(let pairs):
            out.append(0x7B)  // {
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out.append(0x2C) }
                JSONValue.writeString(pair.name, into: &out)
                out.append(0x3A)  // :
                pair.value.write(into: &out)
            }
            out.append(0x7D)  // }
        }
    }

    /// Byte-wise double encoding (String(Double) doesn't link in the Wasm guest).
    /// NaN and the infinities have no JSON representation and encode as null; finite
    /// values use the shared shortest-round-trip formatter (so a JSON API returns
    /// 19.99, not 19.989999999999998).
    private static func writeDouble(_ value: Double, into out: inout [UInt8]) {
        if value != value || value == .infinity || value == -.infinity {
            out.append(contentsOf: Array("null".utf8))
            return
        }
        PlumeDouble.appendFinite(value, into: &out)
    }

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)  // "
        for byte in s.utf8 {
            switch byte {
            case 0x22: out.append(0x5C); out.append(0x22)  // \"
            case 0x5C: out.append(0x5C); out.append(0x5C)  // \\
            case 0x0A: out.append(0x5C); out.append(0x6E)  // \n
            case 0x0D: out.append(0x5C); out.append(0x72)  // \r
            case 0x09: out.append(0x5C); out.append(0x74)  // \t
            case 0..<0x20:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hexDigit(byte >> 4))
                out.append(hexDigit(byte & 0x0F))
            default: out.append(byte)  // UTF-8 passthrough
            }
        }
        out.append(0x22)
    }
}

private func hexDigit(_ value: UInt8) -> UInt8 {
    value < 10 ? 0x30 + value : 0x61 + (value - 10)
}

private func hexValue(_ byte: UInt8) -> Int {
    switch byte {
    case 0x30...0x39: return Int(byte - 0x30)
    case 0x41...0x46: return Int(byte - 0x41 + 10)
    case 0x61...0x66: return Int(byte - 0x61 + 10)
    default: return 0
    }
}

// MARK: - Parser (recursive descent, byte-wise)

public func parseJSON(_ bytes: [UInt8]) -> JSONValue? {
    var parser = JSONParser(bytes: bytes)
    parser.skipWhitespace()
    guard let value = parser.parseValue() else { return nil }
    return value
}

public func parseJSON(_ text: String) -> JSONValue? { parseJSON(Array(text.utf8)) }

private struct JSONParser {
    let bytes: [UInt8]
    var pos = 0
    var depth = 0
    /// Cap nesting so a deeply-nested untrusted body (`[[[[…`) can't overflow the native
    /// stack (a cheap remote crash). Far deeper than any real document.
    static let maxDepth = 512

    mutating func skipWhitespace() {
        while pos < bytes.count {
            let b = bytes[pos]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { pos += 1 } else { break }
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard pos < bytes.count else { return nil }
        switch bytes[pos] {
        case 0x7B, 0x5B:
            guard depth < JSONParser.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            return bytes[pos] == 0x7B ? parseObject() : parseArray()
        case 0x22: return parseString().map { .string($0) }
        case 0x74: return parseLiteral("true", .bool(true))
        case 0x66: return parseLiteral("false", .bool(false))
        case 0x6E: return parseLiteral("null", .null)
        default: return parseNumber()
        }
    }

    mutating func parseLiteral(_ text: String, _ value: JSONValue) -> JSONValue? {
        for expected in text.utf8 {
            guard pos < bytes.count, bytes[pos] == expected else { return nil }
            pos += 1
        }
        return value
    }

    mutating func parseString() -> String? {
        guard pos < bytes.count, bytes[pos] == 0x22 else { return nil }
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count {
            let b = bytes[pos]; pos += 1
            if b == 0x22 { return decodeUTF8(out) }
            if b == 0x5C {
                guard pos < bytes.count else { return nil }
                let e = bytes[pos]; pos += 1
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x75:
                    guard pos + 4 <= bytes.count else { return nil }
                    var cp = 0
                    for _ in 0..<4 { cp = cp * 16 + hexValue(bytes[pos]); pos += 1 }
                    // Combine a UTF-16 surrogate pair (`😀` → 😀) into one scalar;
                    // a lone/invalid surrogate becomes U+FFFD rather than corrupt UTF-8.
                    if cp >= 0xD800, cp <= 0xDBFF {                       // high surrogate
                        if pos + 6 <= bytes.count, bytes[pos] == 0x5C, bytes[pos + 1] == 0x75 {
                            var lo = 0, p = pos + 2
                            for _ in 0..<4 { lo = lo * 16 + hexValue(bytes[p]); p += 1 }
                            if lo >= 0xDC00, lo <= 0xDFFF {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                                pos = p
                            } else { cp = 0xFFFD }
                        } else { cp = 0xFFFD }
                    } else if cp >= 0xDC00, cp <= 0xDFFF {               // lone low surrogate
                        cp = 0xFFFD
                    }
                    appendCodePoint(cp, into: &out)
                default: return nil
                }
            } else {
                out.append(b)  // UTF-8 passthrough
            }
        }
        return nil
    }

    mutating func parseNumber() -> JSONValue? {
        let start = pos
        var isDouble = false
        while pos < bytes.count {
            let b = bytes[pos]
            if b >= 0x30 && b <= 0x39 || b == 0x2D || b == 0x2B { pos += 1 }
            else if b == 0x2E || b == 0x65 || b == 0x45 { isDouble = true; pos += 1 }
            else { break }
        }
        guard pos > start else { return nil }
        if isDouble { return .double(parseDoubleBytes(bytes, start, pos)) }
        let text = decodeUTF8(Array(bytes[start..<pos]))
        return Int64(text).map { .int($0) }
    }

    mutating func parseArray() -> JSONValue? {
        pos += 1  // [
        var items: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == 0x5D { pos += 1; return .array(items) }
        while pos < bytes.count {
            guard let item = parseValue() else { return nil }
            items.append(item)
            skipWhitespace()
            guard pos < bytes.count else { return nil }
            if bytes[pos] == 0x2C { pos += 1; continue }
            if bytes[pos] == 0x5D { pos += 1; return .array(items) }
            return nil
        }
        return nil
    }

    mutating func parseObject() -> JSONValue? {
        pos += 1  // {
        var pairs: [(name: String, value: JSONValue)] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == 0x7D { pos += 1; return .object(pairs) }
        while pos < bytes.count {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == 0x3A else { return nil }
            pos += 1  // :
            guard let value = parseValue() else { return nil }
            pairs.append((name: key, value: value))
            skipWhitespace()
            guard pos < bytes.count else { return nil }
            if bytes[pos] == 0x2C { pos += 1; continue }
            if bytes[pos] == 0x7D { pos += 1; return .object(pairs) }
            return nil
        }
        return nil
    }
}

// Byte-wise float parse — `Double(String)` links `strtod`, which is unavailable
// under embedded wasm. Adequate for JSON values (not bit-exact for all doubles).
private func parseDoubleBytes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Double {
    var i = start
    var sign = 1.0
    if i < end, bytes[i] == 0x2D { sign = -1; i += 1 }
    else if i < end, bytes[i] == 0x2B { i += 1 }

    var value = 0.0
    while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
        value = value * 10 + Double(bytes[i] - 0x30); i += 1
    }
    if i < end, bytes[i] == 0x2E {
        i += 1
        var scale = 1.0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            scale /= 10; value += Double(bytes[i] - 0x30) * scale; i += 1
        }
    }
    if i < end, bytes[i] == 0x65 || bytes[i] == 0x45 {
        i += 1
        var expSign = 1
        if i < end, bytes[i] == 0x2D { expSign = -1; i += 1 }
        else if i < end, bytes[i] == 0x2B { i += 1 }
        // Cap the exponent: 10^309 already overflows Double to inf (and /inf → 0), so a
        // huge exponent (e.g. 1e2000000000) must not spin billions of iterations or
        // overflow `exp` itself — both DoS an untrusted body.
        var exp = 0
        while i < end, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            if exp < 1000 { exp = exp * 10 + Int(bytes[i] - 0x30) }
            i += 1
        }
        var power = 1.0
        for _ in 0..<min(exp, 400) { power *= 10 }
        value = expSign < 0 ? value / power : value * power
    }
    return sign * value
}

private func appendCodePoint(_ cp: Int, into out: inout [UInt8]) {
    if cp < 0x80 {
        out.append(UInt8(cp))
    } else if cp < 0x800 {
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    } else if cp < 0x10000 {
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    } else {
        out.append(UInt8(0xF0 | (cp >> 18)))          // astral plane (4-byte UTF-8)
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    }
}
