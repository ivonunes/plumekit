// Parses `name=value&name=value` (form-urlencoded body or query string) into
// ordered pairs. Operates on UTF-8 bytes and percent-decodes by byte, so it is
// Embedded-clean (no Unicode-aware String operations; their Unicode tables
// don't link under Embedded).
public struct FormParams: Sendable {
    public let values: [(name: String, value: String)]

    public init(_ encoded: String) {
        var pairs: [(name: String, value: String)] = []
        var segment: [UInt8] = []
        func flush() {
            if segment.isEmpty { return }
            var name: [UInt8] = []
            var value: [UInt8] = []
            var sawEquals = false
            for byte in segment {
                if !sawEquals && byte == 0x3D { sawEquals = true; continue }  // '='
                if sawEquals { value.append(byte) } else { name.append(byte) }
            }
            pairs.append((name: FormParams.decode(name), value: FormParams.decode(value)))
            segment = []
        }
        for byte in encoded.utf8 {
            if byte == 0x26 { flush() } else { segment.append(byte) }  // '&'
        }
        flush()
        self.values = pairs
    }

    public subscript(_ name: String) -> String? {
        for pair in values where utf8Equal(pair.name, name) { return pair.value }
        return nil
    }

    /// The value parsed as an Int, or nil.
    public func int(_ name: String) -> Int? {
        guard let value = self[name] else { return nil }
        return Int(value)
    }

    // Percent-decode (`%XX`) and `+` → space, byte-wise.
    private static func decode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x2B {                       // '+'
                out.append(0x20); i += 1
            } else if byte == 0x25 && i + 2 < bytes.count,   // '%XX'
                      let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo)); i += 3
            } else {
                out.append(byte); i += 1
            }
        }
        return decodeUTF8(out)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)         // 0-9
        case 0x41...0x46: return Int(byte - 0x41 + 10)    // A-F
        case 0x61...0x66: return Int(byte - 0x61 + 10)    // a-f
        default: return nil
        }
    }
}

extension Request {
    /// The request body parsed as form-urlencoded parameters.
    public var form: FormParams { FormParams(bodyText) }
    /// The query string parsed as parameters.
    public var queryParams: FormParams { FormParams(query) }
}
