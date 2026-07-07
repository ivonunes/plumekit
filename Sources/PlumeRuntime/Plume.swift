//
//  Plume.swift
//  PlumeRuntime
//
//  Embedded-safe helpers the generated code calls for the small set of Plume
//  filters/methods that survive into request-time rendering. Everything here is
//  byte-wise over UTF-8 — no Foundation, no case-folding, no Unicode collation — so
//  the rendering core never pulls in Swift's Unicode data tables and stays minimal.
//  (App code CAN use native `String ==`/`hasPrefix`/`lowercased` etc.: `plumekit build`
//  links `libswiftUnicodeDataTables.a` into the Wasm build. These helpers stay byte-wise
//  by choice — cheaper, and free of the tables.) Regex, dates, JSON, slugs and similar
//  remain build-time-only and are rejected by the compiling back-end's checker.
//

public enum Plume {
    /// Renders a single component/region standalone — data in, bytes out, with no
    /// ambient request or host. The compiled render functions are already
    /// context-independent; this is just the ergonomic spelling for producing a
    /// fragment to put in a stream envelope.
    public static func fragment(_ render: (inout HTML) -> Void) -> [UInt8] {
        var out = HTML()
        render(&out)
        return out.bytes
    }

    /// `value | default(fallback)` for optionals: nil falls back.
    public static func defaulted<Wrapped>(_ value: Wrapped?, _ fallback: Wrapped) -> Wrapped {
        value ?? fallback
    }

    /// `value | default(fallback)` for strings: empty falls back (Plume treats an
    /// empty string as "missing").
    public static func defaulted(_ value: String, _ fallback: String) -> String {
        value.isEmpty ? fallback : value
    }

    /// `false | default(fallback)` and `[] | default(fallback)` — Plume treats `false`
    /// and an empty array as "missing" too (matching the interpreter's `default`).
    public static func defaulted(_ value: Bool, _ fallback: Bool) -> Bool {
        value ? value : fallback
    }
    public static func defaulted<Element>(_ value: [Element], _ fallback: [Element]) -> [Element] {
        value.isEmpty ? fallback : value
    }

    /// Optional string/array: nil OR empty falls back (the generic `Wrapped?` overload
    /// would only catch nil). More specific than the generic, so it's preferred.
    public static func defaulted(_ value: String?, _ fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }
    public static func defaulted<Element>(_ value: [Element]?, _ fallback: [Element]) -> [Element] {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    // MARK: - Numeric filters (must match the interpreter byte-for-byte)

    // The interpreter promotes numeric filters through `Double` and guards divide-by-zero;
    // the compiling back-end MUST render identically. Raw Swift `/`/`%` on `Int` would
    // truncate (2 vs 2.5) and TRAP on zero, so `dividedBy`/`modulo`/`round` route here.
    // Results render via `HTML.text(Double)`, which is byte-identical to the interpreter's.
    public static func dividedBy(_ value: Double, _ divisor: Double) -> Double {
        divisor == 0 ? 0 : value / divisor
    }
    public static func modulo(_ value: Double, _ divisor: Double) -> Double {
        divisor == 0 ? 0 : value.truncatingRemainder(dividingBy: divisor)
    }
    /// `round(precision)` — precision decimal places (0 = whole), matching the interpreter.
    public static func rounded(_ value: Double, _ precision: Double) -> Double {
        var multiplier = 1.0
        var places = max(0, Int(precision))
        while places > 0 { multiplier *= 10; places -= 1 }   // 10^precision, no libm `pow`
        return (value * multiplier).rounded() / multiplier
    }

    /// Render a numeric-filter result exactly as the interpreter's `numeric` does: a whole
    /// value as an integer (`4`), otherwise the shortest Double (`3.5`) — so the compiled
    /// output stays byte-identical (`out.text(Double)` alone would emit `4.0`).
    public static func numericString(_ value: Double) -> String {
        var html = HTML()
        let whole = value.rounded()
        if whole == value, let int = Int(exactly: whole) { html.text(int) } else { html.text(value) }
        return String(decoding: html.bytes, as: UTF8.self)
    }

    // MARK: - Equality (byte-wise for strings)

    /// Byte-wise string equality — no Unicode tables, so it's the cheapest comparison
    /// and adds nothing to the guest's size. App code can also use native `String ==`
    /// now (with full Unicode semantics, incl. canonical equivalence): `plumekit build`
    /// links Swift's Unicode data tables into the Wasm build. Prefer this helper in
    /// framework-internal or size-critical paths; use `String ==` when you specifically
    /// want canonical-equivalent, human-text comparison.
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf8.makeIterator()
        var right = rhs.utf8.makeIterator()
        while true {
            let l = left.next()
            let r = right.next()
            if l == nil && r == nil { return true }
            if l != r { return false }
        }
    }

    /// Equality for non-string equatable values (e.g. `Int`), where `==` is
    /// Embedded-safe.
    public static func equal<Value: Equatable>(_ lhs: Value, _ rhs: Value) -> Bool {
        lhs == rhs
    }

    // MARK: - Byte-wise string predicates

    public static func hasPrefix(_ value: String, _ prefix: String) -> Bool {
        bytesHavePrefix(value, prefix)
    }

    public static func hasSuffix(_ value: String, _ suffix: String) -> Bool {
        let valueBytes = Array(value.utf8)
        let suffixBytes = Array(suffix.utf8)
        guard suffixBytes.count <= valueBytes.count else { return false }
        let offset = valueBytes.count - suffixBytes.count
        var index = 0
        while index < suffixBytes.count {
            if valueBytes[offset + index] != suffixBytes[index] { return false }
            index += 1
        }
        return true
    }

    public static func contains(_ value: String, _ needle: String) -> Bool {
        let haystack = Array(value.utf8)
        let needleBytes = Array(needle.utf8)
        if needleBytes.isEmpty { return true }
        guard needleBytes.count <= haystack.count else { return false }
        var start = 0
        let last = haystack.count - needleBytes.count
        while start <= last {
            var index = 0
            while index < needleBytes.count, haystack[start + index] == needleBytes[index] {
                index += 1
            }
            if index == needleBytes.count { return true }
            start += 1
        }
        return false
    }

    /// `tags.contains(value)` for string arrays, compared byte-wise so it never
    /// pulls in `String ==`'s Unicode tables (which fail to LINK under Embedded).
    public static func contains(_ array: [String], _ element: String) -> Bool {
        for candidate in array where equal(candidate, element) { return true }
        return false
    }

    /// `array.contains(element)` for non-string equatable element types
    /// (e.g. `[Int]`), where `==` is Embedded-safe.
    public static func contains<Element: Equatable>(_ array: [Element], _ element: Element) -> Bool {
        array.contains(element)
    }

    private static func bytesHavePrefix(_ value: String, _ prefix: String) -> Bool {
        var valueIterator = value.utf8.makeIterator()
        for prefixByte in prefix.utf8 {
            guard let valueByte = valueIterator.next(), valueByte == prefixByte else {
                return false
            }
        }
        return true
    }
}

// MARK: - Truthiness (documented Plume conditional semantics)
//
// `@if value` follows Plume truthiness: false, empty strings, empty arrays, and
// nil are falsey; numbers, non-empty strings/arrays are truthy. The compiling
// back-end lowers every plain condition through these overloads so a `String`
// or optional condition compiles (and matches the interpreting renderer).
extension Plume {
    public static func truthy(_ value: Bool) -> Bool { value }

    public static func truthy(_ value: String) -> Bool {
        var iterator = value.utf8.makeIterator()
        guard iterator.next() != nil else { return false }   // empty is falsy
        return !equal(value, "false")                        // "false" is falsy (matches the interpreter)
    }

    public static func truthy(_ value: Int) -> Bool { value != 0 }
    public static func truthy(_ value: Int64) -> Bool { value != 0 }
    public static func truthy(_ value: Double) -> Bool { value != 0 }

    public static func truthy<Element>(_ value: [Element]) -> Bool { !value.isEmpty }

    public static func truthy(_ value: Bool?) -> Bool { value ?? false }
    public static func truthy(_ value: String?) -> Bool { value.map { truthy($0) } ?? false }
    public static func truthy(_ value: Int?) -> Bool { value.map { truthy($0) } ?? false }
    public static func truthy(_ value: Int64?) -> Bool { value.map { truthy($0) } ?? false }
    public static func truthy(_ value: Double?) -> Bool { value.map { truthy($0) } ?? false }
    public static func truthy<Element>(_ value: [Element]?) -> Bool { value.map { !$0.isEmpty } ?? false }

    /// Any other non-optional value (models, structs) is truthy by presence.
    public static func truthy<Value>(_ value: Value?) -> Bool { value != nil }
}

extension Plume {
    /// The HTML-escaped string form of a value. The `escape` filter uses this so a
    /// following `raw` emits the entities as-is (matching the interpreter) rather than
    /// re-exposing the source. Escaping goes through `HTML.text`, which is byte-for-byte
    /// identical to the interpreter's escaper.
    private static func renderEscaped(_ write: (inout HTML) -> Void) -> String {
        var h = HTML(); write(&h); return String(decoding: h.bytes, as: UTF8.self)
    }
    public static func escaped(_ value: String) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: String?) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Substring) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Int) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Int?) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Double) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Double?) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Bool) -> String { renderEscaped { $0.text(value) } }
    public static func escaped(_ value: Bool?) -> String { renderEscaped { $0.text(value) } }
}
