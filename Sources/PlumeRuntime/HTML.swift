//
//  HTML.swift
//  PlumeRuntime
//
//  The output buffer that Plume's compiling back-end writes into. This target is
//  Embedded-Swift-clean: it imports no Foundation, uses no existentials/`any`,
//  no reflection, no `Any`/`AnyObject`, and never relies on `String ==`,
//  case-folding, or Unicode collation (those fail to LINK under Embedded because
//  the Unicode tables are absent). All text handling operates on UTF-8 bytes.
//
//  The same source compiles unchanged under the regular Swift toolchain (so the
//  native test-suite can drive it) and under the Embedded-Swift Wasm SDK.
//

/// A streaming, `[UInt8]`-backed HTML output buffer.
///
/// Generated `render` functions append three kinds of content:
///   * `literal(_:)` — verbatim template chrome (authored HTML), no escaping.
///   * `text(_:)`    — dynamic, untrusted values: HTML-escaped byte by byte (the default).
///   * `raw(_:)`     — the explicit unescaped opt-out for already-safe HTML.
public struct HTML {
    public private(set) var bytes: [UInt8]

    /// The bundle assets this response needs — the stylesheet (set by `@style`
    /// sites) and the client script (set by `@script`/`@state`/`@navigation` sites) —
    /// and whether they were already spliced into the `<head>`.
    public private(set) var stylesheetHref: String? = nil
    public private(set) var scriptHref: String? = nil
    public private(set) var assetsInjected = false

    public init() {
        bytes = []
    }

    public init(reservingCapacity capacity: Int) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    @inline(__always)
    public mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    @inline(__always)
    public mutating func append(_ buffer: UnsafeBufferPointer<UInt8>) {
        bytes.append(contentsOf: buffer)
    }

    /// Appends already-rendered HTML bytes verbatim (e.g. a fragment to embed).
    @inline(__always)
    public mutating func append(_ rendered: [UInt8]) {
        bytes.append(contentsOf: rendered)
    }

    // MARK: - Verbatim template chrome

    /// Emits authored template text verbatim. Generated code uses this for the
    /// static HTML between interpolations, so it never allocates a `String`.
    @inline(__always)
    public mutating func literal(_ value: StaticString) {
        value.withUTF8Buffer { bytes.append(contentsOf: $0) }
    }

    /// Record that this response needs the app's compiled style bundle. Generated
    /// render functions call this wherever a template declares `@style` — nothing is
    /// emitted inline; `injectRequiredAssets()` splices one `<link>` into the
    /// document's `<head>` at the response boundary, so the link lands in the head
    /// no matter where in the page the first `@style` appears.
    public mutating func requireStylesheet(_ href: String) {
        // Pattern-match, not `== nil`: Optional<String> equality routes through
        // `String ==` in debug builds, which doesn't link under Embedded.
        guard case .none = stylesheetHref else { return }
        stylesheetHref = href
    }

    /// Record that this response needs the app's compiled client script (the Plume
    /// runtime + `@script` code). Set wherever a template declares `@script`,
    /// `@state`, or `@navigation`.
    public mutating func requireScript(_ href: String) {
        guard case .none = scriptHref else { return }
        scriptHref = href
    }

    /// Splice the required bundle tags right after `<head…>`, once. Called by the
    /// app's `Response.view(_:)` bridge before the bytes go on the wire. The tags
    /// carry `data-plume-track` so the navigation runtime can detect a deploy (a
    /// changed content hash) and fall back to a full page load instead of swapping
    /// against stale assets. A render with no `<head>` (a fragment for a stream
    /// envelope) is left untouched — the receiving page already loaded the bundle.
    public mutating func injectRequiredAssets() {
        var required = false
        if case .some = stylesheetHref { required = true }
        if case .some = scriptHref { required = true }
        guard !assetsInjected, required else { return }
        guard let insertAt = headInsertionIndex() else { return }
        assetsInjected = true
        var tags = HTML()
        if let href = stylesheetHref {
            tags.literal("<link rel=\"stylesheet\" data-plume-track href=\"")
            tags.text(href)
            tags.literal("\">")
        }
        if let href = scriptHref {
            // Compiled-mode localization for `@script`: inject the active locale's
            // strings and define `window.t` here, so a client script can call
            // `t("key")`. Because this only happens in the compiled render path,
            // `t` is undefined under the interpreter — translations aren't available
            // there by design. Placed before the deferred bundle so it runs first.
            if let state = RenderContext.localization {
                tags.literal("<script>window.__plumeI18n=")
                tags.bytes.append(contentsOf: Array(state.currentTableJSON.utf8))   // pre-escaped JSON
                tags.literal(";window.t=function(k,p){var m=window.__plumeI18n||{};var s=Object.prototype.hasOwnProperty.call(m,k)?m[k]:k;return p?s.replace(/\\{(\\w+)\\}/g,function(x,n){return Object.prototype.hasOwnProperty.call(p,n)?p[n]:x}):s};</script>")
            }
            tags.literal("<script defer data-plume-track src=\"")
            tags.text(href)
            tags.literal("\"></script>")
        }
        bytes.insert(contentsOf: tags.bytes, at: insertAt)
    }

    /// The byte index just past the document's opening `<head…>` tag, or nil.
    private func headInsertionIndex() -> Int? {
        let head: [UInt8] = [0x3C, 0x68, 0x65, 0x61, 0x64]   // "<head"
        guard bytes.count >= head.count else { return nil }
        func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte }
        var i = 0
        while i <= bytes.count - head.count {
            if bytes[i] == 0x3C {
                var match = true
                for j in 1..<head.count where lower(bytes[i + j]) != head[j] { match = false; break }
                // The tag must end here (">" or an attribute), not be "<header…".
                if match, i + head.count < bytes.count {
                    let next = bytes[i + head.count]
                    if next == 0x3E || next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D {
                        var k = i + head.count
                        while k < bytes.count, bytes[k] != 0x3E { k += 1 }
                        return k < bytes.count ? k + 1 : nil
                    }
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Escaped dynamic text (the default)

    /// Appends `value`, HTML-escaping `&  <  >  "  '` byte by byte.
    public mutating func text(_ value: String) {
        appendEscaped(value.utf8)
    }

    /// Appends an escaped `Substring` without first copying it to a `String`.
    public mutating func text(_ value: Substring) {
        appendEscaped(value.utf8)
    }

    /// Renders an optional, treating `nil` as the empty string (matching Plume's
    /// interpreting renderer, where a missing value stringifies to "").
    public mutating func text(_ value: String?) {
        if let value { appendEscaped(value.utf8) }
    }

    public mutating func text(_ value: Int) { appendInteger(value) }
    public mutating func text(_ value: Int?) { if let value { appendInteger(value) } }
    public mutating func text(_ value: Bool) { literal(value ? "true" : "false") }
    public mutating func text(_ value: Bool?) { if let value { text(value) } }
    public mutating func text(_ value: Double) { appendDouble(value) }
    public mutating func text(_ value: Double?) { if let value { appendDouble(value) } }

    // MARK: - Raw, unescaped dynamic text (explicit opt-out)

    /// Appends `value` with no escaping. The template author opted out of escaping
    /// (e.g. `{ value | raw }`); the value is assumed to be safe HTML.
    public mutating func raw(_ value: String) {
        bytes.append(contentsOf: value.utf8)
    }

    public mutating func raw(_ value: Substring) {
        bytes.append(contentsOf: value.utf8)
    }

    public mutating func raw(_ value: String?) {
        if let value { bytes.append(contentsOf: value.utf8) }
    }

    // MARK: - JSON values (for the serialized @state hook)

    /// Writes a JSON-encoded value. Strings are quoted and escaped (including
    /// `<` as `<` so the JSON is safe inside a `<script>` element);
    /// optionals encode `nil` as `null`. Byte-wise and Embedded-clean.
    public mutating func jsonValue(_ value: String) { appendJSONString(value) }
    public mutating func jsonValue(_ value: String?) {
        if let value { appendJSONString(value) } else { literal("null") }
    }
    public mutating func jsonValue(_ value: Bool) { literal(value ? "true" : "false") }
    public mutating func jsonValue(_ value: Bool?) {
        if let value { jsonValue(value) } else { literal("null") }
    }
    public mutating func jsonValue(_ value: Int) { appendInteger(value) }
    public mutating func jsonValue(_ value: Int?) {
        if let value { appendInteger(value) } else { literal("null") }
    }
    public mutating func jsonValue(_ value: Double) { appendDouble(value) }
    public mutating func jsonValue(_ value: Double?) {
        if let value { appendDouble(value) } else { literal("null") }
    }

    mutating func appendJSONString(_ value: String) {
        bytes.append(PlumeASCII.doubleQuote)
        for byte in value.utf8 { appendJSONByte(byte) }
        bytes.append(PlumeASCII.doubleQuote)
    }

    @inline(__always)
    mutating func appendJSONByte(_ byte: UInt8) {
        switch byte {
        case PlumeASCII.doubleQuote: literal("\\\"")
        case PlumeASCII.backslash: literal("\\\\")
        case 0x08: literal("\\b")
        case 0x0C: literal("\\f")
        case 0x0A: literal("\\n")
        case 0x0D: literal("\\r")
        case 0x09: literal("\\t")
        case PlumeASCII.lessThan: literal("\\u003c")  // </script> safety
        default:
            if byte < 0x20 {
                literal("\\u00")
                bytes.append(hexDigit(byte >> 4))
                bytes.append(hexDigit(byte & 0x0F))
            } else {
                bytes.append(byte)
            }
        }
    }

    @inline(__always)
    func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? (PlumeASCII.zero + nibble) : (0x61 + nibble - 10)  // 0-9, a-f
    }

    // MARK: - Byte-wise escaping

    @inline(__always)
    mutating func appendEscaped(_ utf8: String.UTF8View) {
        for byte in utf8 { appendEscapedByte(byte) }
    }

    @inline(__always)
    mutating func appendEscaped(_ utf8: Substring.UTF8View) {
        for byte in utf8 { appendEscapedByte(byte) }
    }

    @inline(__always)
    mutating func appendEscapedByte(_ byte: UInt8) {
        switch byte {
        case PlumeASCII.ampersand: literal("&amp;")
        case PlumeASCII.lessThan: literal("&lt;")
        case PlumeASCII.greaterThan: literal("&gt;")
        case PlumeASCII.doubleQuote: literal("&quot;")
        case PlumeASCII.singleQuote: literal("&#39;")
        default: bytes.append(byte)
        }
    }

    // MARK: - Integer formatting (byte-wise, no Foundation / no String(Int))

    mutating func appendInteger<Value: BinaryInteger>(_ value: Value) {
        if value == 0 {
            bytes.append(PlumeASCII.zero)
            return
        }
        var magnitude = value.magnitude
        // Collect digits least-significant first into a fixed scratch buffer.
        var scratch = [UInt8]()
        scratch.reserveCapacity(20)
        while magnitude > 0 {
            let digit = UInt8(truncatingIfNeeded: magnitude % 10)
            scratch.append(PlumeASCII.zero + digit)
            magnitude /= 10
        }
        if value < 0 { bytes.append(PlumeASCII.hyphen) }
        var index = scratch.count - 1
        while index >= 0 {
            bytes.append(scratch[index])
            index -= 1
        }
    }

    // MARK: - Double formatting (best-effort, byte-wise, no Foundation)

    /// Formats `value` to match the interpreting renderer's `String(Double)` — the
    /// shortest decimal that round-trips (`3.14159` -> "3.14159"). See `PlumeDouble`.
    mutating func appendDouble(_ value: Double) {
        if value != value { literal("nan"); return }
        if value == Double.infinity { literal("inf"); return }
        if value == -Double.infinity { literal("-inf"); return }
        PlumeDouble.appendFinite(value, into: &bytes)
    }
}

/// Byte-wise shortest-round-trip `Double` formatting, shared by the compiled render
/// path (`HTML.appendDouble`) and JSON serialization so both agree with the
/// interpreter's `String(Double)` — and so neither leaks float error (19.99, not
/// 19.989999999999998). Byte-wise so it links in the embedded guest, where
/// `String(Double)` is unavailable. The caller handles NaN/±inf per its own policy
/// ("nan"/"inf" for HTML, "null" for JSON).
public enum PlumeDouble {
    /// Append the shortest decimal that reconstructs to exactly `value` (assumed
    /// finite). Mirrors Swift's fixed/scientific threshold. For |exponent| > 22
    /// (1e100 and the like, which never appear in real output) 10^n isn't an exact
    /// Double, so the round-trip can't confirm the shortest form and it falls back to
    /// 17 digits.
    public static func appendFinite(_ value: Double, into out: inout [UInt8]) {
        if value == 0 {
            if value.sign == .minus { out.append(0x2D) }        // '-'
            out.append(contentsOf: [0x30, 0x2E, 0x30])          // "0.0"
            return
        }
        var d = value
        if d < 0 { out.append(0x2D); d = -d }
        var exp10 = decimalExponent(d)
        var digits: [UInt8] = []
        var p = 1
        while p <= 17 {
            let (extracted, carried) = significantDigits(d, exp10: exp10, count: p)
            let e = exp10 + carried
            if reconstruct(extracted, exp10: e) == d { digits = extracted; exp10 = e; break }
            if p == 17 { digits = extracted; exp10 = e }
            p += 1
        }
        while digits.count > 1, digits[digits.count - 1] == 0 { digits.removeLast() }
        emitDecimal(digits, exp10: exp10, into: &out)
    }

    /// floor(log10(d)) for d > 0, found by scaling (no libm).
    static func decimalExponent(_ d: Double) -> Int {
        var exp = 0
        var m = d
        while m >= 10 { m /= 10; exp += 1 }
        while m < 1 { m *= 10; exp -= 1 }
        return exp
    }

    /// The first `count` significant digits of `d` (0...9), rounded. `carry` is 1 when
    /// rounding overflowed the leading digit (9.99 -> 10, exp += 1).
    static func significantDigits(_ d: Double, exp10: Int, count: Int) -> (digits: [UInt8], carry: Int) {
        var m = d
        if exp10 >= 0 { for _ in 0..<exp10 { m /= 10 } } else { for _ in 0..<(-exp10) { m *= 10 } }
        var out: [UInt8] = []
        for _ in 0..<count {
            var digit = Int(m)
            if digit < 0 { digit = 0 }; if digit > 9 { digit = 9 }
            out.append(UInt8(digit))
            m = (m - Double(digit)) * 10
        }
        if m >= 5 {   // round half-up on the next digit
            var i = count - 1
            while i >= 0 { out[i] += 1; if out[i] < 10 { break }; out[i] = 0; i -= 1 }
            if i < 0 { out.insert(1, at: 0); out.removeLast(); return (out, 1) }
        }
        return (out, 0)
    }

    /// Render significant `digits` with leading-digit exponent `exp10`, matching
    /// `String(Double)`: fixed notation for exp10 in [-4, 15], scientific outside.
    static func emitDecimal(_ digits: [UInt8], exp10: Int, into out: inout [UInt8]) {
        func ch(_ v: UInt8) -> UInt8 { 0x30 + v }
        if exp10 < -4 || exp10 > 15 {
            out.append(ch(digits[0]))
            if digits.count > 1 {   // single-digit mantissa drops the point: "1e-05"
                out.append(0x2E)
                for i in 1..<digits.count { out.append(ch(digits[i])) }
            }
            out.append(0x65)                                   // 'e'
            out.append(exp10 < 0 ? 0x2D : 0x2B)                // '-' / '+'
            let mag = exp10 < 0 ? -exp10 : exp10
            if mag < 10 { out.append(0x30) }                   // ≥2-digit exponent
            appendUInt(mag, into: &out)
        } else if exp10 >= 0 {
            let intCount = exp10 + 1
            for i in 0..<intCount { out.append(ch(i < digits.count ? digits[i] : 0)) }
            out.append(0x2E)
            if intCount >= digits.count { out.append(0x30) }
            else { for i in intCount..<digits.count { out.append(ch(digits[i])) } }
        } else {
            out.append(0x30); out.append(0x2E)                 // "0."
            for _ in 0..<(-exp10 - 1) { out.append(0x30) }
            for v in digits { out.append(ch(v)) }
        }
    }

    private static func appendUInt(_ n: Int, into out: inout [UInt8]) {
        if n == 0 { out.append(0x30); return }
        var digits: [UInt8] = []
        var v = n
        while v > 0 { digits.append(0x30 + UInt8(v % 10)); v /= 10 }
        out.append(contentsOf: digits.reversed())
    }

    /// The Double that significant `digits` with leading-digit exponent `exp10` denote.
    static func reconstruct(_ digits: [UInt8], exp10: Int) -> Double {
        var mantissa = 0.0
        for v in digits { mantissa = mantissa * 10 + Double(v) }
        // value = mantissa × 10^power. Build 10^|power| as a SINGLE factor (exact for
        // |power| ≤ 22) and apply once, so the result is correctly rounded — repeated
        // ×10/÷10 would accumulate error and defeat the round-trip check.
        let power = exp10 - (digits.count - 1)
        if power == 0 { return mantissa }
        var factor = 1.0
        var k = power < 0 ? -power : power
        while k > 0 { factor *= 10; k -= 1 }
        return power > 0 ? mantissa * factor : mantissa / factor
    }
}

enum PlumeASCII {
    static let ampersand: UInt8 = 0x26   // &
    static let singleQuote: UInt8 = 0x27 // '
    static let backslash: UInt8 = 0x5C   // \
    static let hyphen: UInt8 = 0x2D      // -
    static let zero: UInt8 = 0x30        // 0
    static let dot: UInt8 = 0x2E         // .
    static let lessThan: UInt8 = 0x3C    // <
    static let greaterThan: UInt8 = 0x3E // >
    static let doubleQuote: UInt8 = 0x22 // "
}
