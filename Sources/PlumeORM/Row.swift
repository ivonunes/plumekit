import PlumeCore

// A reflection-free, POSITIONAL row decoder. The query builder always projects
// columns in `schema.columns` order, so the generated `init(row:)` reads by index
// (`row.int(0)`, `row.string(1)`, …) and NEVER matches on column name — matching
// names would need Unicode-aware `String ==`, which fails to link under embedded
// wasm. This same shape is reusable as a generic field decoder for JSON.
public struct Row {
    public let values: [SQLValue]
    public init(_ values: [SQLValue]) { self.values = values }

    /// The raw column value, untyped — used to carry a relation's foreign key of any
    /// primary-key type (Int, UUID text, …) without assuming which.
    public func value(_ i: Int) -> SQLValue { values[i] }

    public func int(_ i: Int) -> Int {
        // `Int` is 32-bit on the wasm guest, so a 64-bit column value past 2^31 would
        // trap `Int(n)`; wrap instead of crashing (use an `Int64` field for big values).
        // Also coerce a `.double` cell (SQLite dynamic typing / `AVG` can hand one back)
        // instead of silently returning 0.
        switch values[i] {
        case .integer(let n): return Int(truncatingIfNeeded: n)
        case .double(let d): return Int64(exactly: d.rounded(.towardZero)).map { Int(truncatingIfNeeded: $0) } ?? 0
        default: return 0
        }
    }
    public func int64(_ i: Int) -> Int64 {
        switch values[i] {
        case .integer(let n): return n
        case .double(let d): return Int64(exactly: d.rounded(.towardZero)) ?? 0
        default: return 0
        }
    }
    public func string(_ i: Int) -> String {
        if case .text(let s) = values[i] { return s }
        return ""
    }
    public func uuid(_ i: Int) -> UUID {
        if case .text(let s) = values[i] { return UUID(s) }
        return .zero
    }
    public func bool(_ i: Int) -> Bool {
        if case .integer(let n) = values[i] { return n != 0 }
        return false
    }
    public func double(_ i: Int) -> Double {
        if case .double(let d) = values[i] { return d }
        if case .integer(let n) = values[i] { return Double(n) }
        return 0
    }
    public func bytes(_ i: Int) -> [UInt8] {
        if case .blob(let b) = values[i] { return b }
        return []
    }
    public func isNull(_ i: Int) -> Bool {
        if case .null = values[i] { return true }
        return false
    }

    // Null-aware accessors for nullable columns. A real SQL NULL decodes to `nil`
    // (never a silent 0/""/false), so an adopted schema's nullable columns round-trip
    // faithfully. Any non-matching/NULL value yields `nil`.
    public func intOptional(_ i: Int) -> Int? {
        // `Int(truncatingIfNeeded:)`, NOT `Int(n)`: the latter traps on the 32-bit guest for
        // a value past 2^31 (a nullable Int column would crash where the non-nullable one
        // doesn't). Coerce `.double` too, mirroring `int(_:)`.
        switch values[i] {
        case .integer(let n): return Int(truncatingIfNeeded: n)
        case .double(let d): return Int64(exactly: d.rounded(.towardZero)).map { Int(truncatingIfNeeded: $0) }
        default: return nil
        }
    }
    public func int64Optional(_ i: Int) -> Int64? {
        switch values[i] {
        case .integer(let n): return n
        case .double(let d): return Int64(exactly: d.rounded(.towardZero))
        default: return nil
        }
    }
    public func stringOptional(_ i: Int) -> String? {
        if case .text(let s) = values[i] { return s }
        return nil
    }
    public func uuidOptional(_ i: Int) -> UUID? {
        if case .text(let s) = values[i] { return UUID(uuidString: s) }
        return nil
    }
    public func boolOptional(_ i: Int) -> Bool? {
        if case .integer(let n) = values[i] { return n != 0 }
        return nil
    }
    public func doubleOptional(_ i: Int) -> Double? {
        if case .double(let d) = values[i] { return d }
        if case .integer(let n) = values[i] { return Double(n) }
        return nil
    }
    public func bytesOptional(_ i: Int) -> [UInt8]? {
        if case .blob(let b) = values[i] { return b }
        return nil
    }
}
