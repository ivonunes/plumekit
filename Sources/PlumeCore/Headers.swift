/// An ordered, case-insensitive collection of HTTP header fields.
///
/// Backed by an array of pairs rather than a `Dictionary` so that ordering and
/// duplicate field names are preserved, and so the type stays trivially
/// Embedded-clean. Field-name comparison is ASCII-case-insensitive per RFC 9110.
public struct Headers: Sendable, Equatable {
    public private(set) var fields: [(name: String, value: String)]

    public init() {
        self.fields = []
    }

    public init(_ fields: [(String, String)]) {
        self.fields = fields.map { (name: $0.0, value: $0.1) }
    }

    /// First value for `name`, case-insensitively, or nil.
    public func first(_ name: String) -> String? {
        for field in fields where asciiCaseInsensitiveEqual(field.name, name) {
            return field.value
        }
        return nil
    }

    /// All values for `name`, case-insensitively, in order.
    public func all(_ name: String) -> [String] {
        var out: [String] = []
        for field in fields where asciiCaseInsensitiveEqual(field.name, name) {
            out.append(field.value)
        }
        return out
    }

    /// Append a header field, preserving any existing fields with the same name.
    public mutating func add(_ name: String, _ value: String) {
        fields.append((name: name, value: value))
    }

    /// Replace all fields named `name` with a single field carrying `value`.
    public mutating func set(_ name: String, _ value: String) {
        fields.removeAll { asciiCaseInsensitiveEqual($0.name, name) }
        fields.append((name: name, value: value))
    }

    public static func == (lhs: Headers, rhs: Headers) -> Bool {
        guard lhs.fields.count == rhs.fields.count else { return false }
        for i in 0..<lhs.fields.count {
            if !utf8Equal(lhs.fields[i].name, rhs.fields[i].name) { return false }
            if !utf8Equal(lhs.fields[i].value, rhs.fields[i].value) { return false }
        }
        return true
    }
}

/// Byte-wise prefix test (`String.hasPrefix` is Unicode-aware and not Embedded-safe).
func asciiHasPrefix(_ string: String, _ prefix: String) -> Bool {
    let su = Array(string.utf8)
    let pu = Array(prefix.utf8)
    if su.count < pu.count { return false }
    for i in 0..<pu.count where su[i] != pu[i] { return false }
    return true
}

/// ASCII-only, allocation-free case-insensitive string comparison.
/// Foundation's `caseInsensitiveCompare` is unavailable under Embedded Swift.
func asciiCaseInsensitiveEqual(_ a: String, _ b: String) -> Bool {
    let au = a.utf8
    let bu = b.utf8
    if au.count != bu.count { return false }
    var ai = au.makeIterator()
    var bi = bu.makeIterator()
    while let x = ai.next(), let y = bi.next() {
        if asciiLower(x) != asciiLower(y) { return false }
    }
    return true
}

@inline(__always)
private func asciiLower(_ c: UInt8) -> UInt8 {
    // 'A'...'Z' -> 'a'...'z'
    (c >= 65 && c <= 90) ? c &+ 32 : c
}
