// Request-data validation. Validate incoming form or JSON fields
// against per-field rules, then read typed values or per-field error messages back.
// Byte-wise throughout (no regex engine, no Foundation) so it links in the Wasm guest.
//
//     let input = request.validate([
//         ("email",    [.required, .email]),
//         ("age",      [.required, .integer, .min(18)]),
//         ("password", [.required, .minLength(8)]),
//     ])
//     guard input.isValid else { return .json(input.errors.jsonValue, status: 422) }
//     let email = input.string("email")

/// A single validation rule for a field.
public enum ValidationRule: Sendable {
    case required
    case email
    case integer
    case decimal
    case min(Int)            // numeric: the parsed integer value is ≥ n
    case max(Int)            // numeric: the parsed integer value is ≤ n
    case minLength(Int)      // string length (UTF-8 code units)
    case maxLength(Int)
    case oneOf([String])     // value must be one of these
    case sameAs(String)      // value must equal another field (e.g. password confirmation)
    case check(String, @Sendable (String) -> Bool)   // custom: (message, predicate)
}

/// Per-field validation errors.
public struct ValidationErrors: Sendable {
    public let byField: [(field: String, messages: [String])]

    public var isEmpty: Bool { byField.isEmpty }
    public var all: [String] { byField.flatMap { $0.messages } }

    public func messages(_ field: String) -> [String] {
        for entry in byField where utf8Equal(entry.field, field) { return entry.messages }
        return []
    }

    /// The field's first error message, or "" — shaped for inline display in a view:
    /// `@if titleError != "" {<span class="field-error">{titleError}</span>}`.
    public func first(_ field: String) -> String {
        messages(field).first ?? ""
    }

    /// `{"email": ["is required"], …}` as a `JSONValue` (reuses the JSON encoder for a
    /// 422 body: `return .json(input.errors.jsonValue, status: 422)`).
    public var jsonValue: JSONValue {
        .object(byField.map { (name: $0.field, value: JSONValue.array($0.messages.map { .string($0) })) })
    }
}

/// The result of `Request.validate`: validity, errors, and the read field values.
public struct ValidatedInput: Sendable {
    public let isValid: Bool
    public let errors: ValidationErrors
    let values: [(field: String, value: String)]

    public func string(_ field: String) -> String {
        for entry in values where utf8Equal(entry.field, field) { return entry.value }
        return ""
    }
    public func int(_ field: String) -> Int? { parseValidationInt(string(field)) }
    public func bool(_ field: String) -> Bool {
        let v = string(field)
        return utf8Equal(v, "true") || utf8Equal(v, "1") || utf8Equal(v, "on") || utf8Equal(v, "yes")
    }
}

extension Request {
    /// Read a field from the JSON body (when the request is JSON) or the urlencoded form.
    public func input(_ name: String) -> String? {
        if hasJSONBody, let value = json()?[name] { return jsonScalarString(value) }
        return form[name]
    }

    /// Validate request input against per-field rules. Empty non-required fields are
    /// skipped; an empty required field reports "is required".
    public func validate(_ rules: [(String, [ValidationRule])]) -> ValidatedInput {
        var errorPairs: [(field: String, messages: [String])] = []
        var values: [(field: String, value: String)] = []

        for (field, fieldRules) in rules {
            let raw = input(field) ?? ""
            values.append((field, raw))

            let required = fieldRules.contains { if case .required = $0 { return true }; return false }
            if raw.isEmpty {
                if required { errorPairs.append((field, ["is required"])) }
                continue
            }
            var messages: [String] = []
            for rule in fieldRules {
                if case .required = rule { continue }   // already handled
                if let message = validationMessage(for: rule, value: raw) { messages.append(message) }
            }
            if !messages.isEmpty { errorPairs.append((field, messages)) }
        }

        let errors = ValidationErrors(byField: errorPairs)
        return ValidatedInput(isValid: errors.isEmpty, errors: errors, values: values)
    }

    private func validationMessage(for rule: ValidationRule, value: String) -> String? {
        switch rule {
        case .required:
            return nil   // handled in validate()
        case .email:
            return isValidEmailAddress(value) ? nil : "must be a valid email address"
        case .integer:
            return parseValidationInt(value) != nil ? nil : "must be a whole number"
        case .decimal:
            return isDecimalString(value) ? nil : "must be a number"
        case .min(let n):
            guard let v = parseValidationInt(value) else { return "must be a number" }
            return v >= n ? nil : "must be at least \(n)"
        case .max(let n):
            guard let v = parseValidationInt(value) else { return "must be a number" }
            return v <= n ? nil : "must be at most \(n)"
        case .minLength(let n):
            return value.utf8.count >= n ? nil : "must be at least \(n) characters"
        case .maxLength(let n):
            return value.utf8.count <= n ? nil : "must be at most \(n) characters"
        case .oneOf(let options):
            // Byte-wise membership — [String].contains drags Unicode normalization
            // into the Embedded wasm link (the Unicode Link Law).
            var matched = false
            for option in options where utf8Equal(option, value) { matched = true }
            return matched ? nil : "is not a valid option"
        case .sameAs(let other):
            return utf8Equal(value, input(other) ?? "") ? nil : "must match \(other)"
        case .check(let message, let predicate):
            return predicate(value) ? nil : message
        }
    }
}

// MARK: - Byte-wise helpers (Embedded-safe; no Foundation, no regex)

/// A scalar JSON value as a string (for validation input). Objects/arrays/null → nil.
private func jsonScalarString(_ value: JSONValue) -> String? {
    switch value {
    case .string(let s): return s
    case .int(let n): return String(n)
    case .bool(let b): return b ? "true" : "false"
    case .double(let d):
        // `Int64(d)` traps on NaN/inf or |d| ≥ 2^63 (an untrusted JSON number) — guard it.
        guard d == d.rounded(), d.isFinite, d >= -9.223372036854776e18, d < 9.223372036854776e18 else { return nil }
        return String(Int64(d))
    default: return nil
    }
}

/// Parse a base-10 integer (optional leading `-`), or nil. Byte-wise.
func parseValidationInt(_ s: String) -> Int? {
    let bytes = Array(s.utf8)
    if bytes.isEmpty { return nil }
    var index = 0
    var negative = false
    if bytes[0] == 0x2d { negative = true; index = 1; if bytes.count == 1 { return nil } }
    var value = 0
    while index < bytes.count {
        let b = bytes[index]
        if b < 0x30 || b > 0x39 { return nil }
        // Overflow-checked so a long digit string (attacker-controlled field) returns
        // nil instead of trapping — `Int` is only 32-bit on the Wasm guest.
        let (mul, o1) = value.multipliedReportingOverflow(by: 10)
        let (sum, o2) = mul.addingReportingOverflow(Int(b - 0x30))
        if o1 || o2 { return nil }
        value = sum
        index += 1
    }
    return negative ? -value : value
}

/// Whether the string is a decimal number (digits, at most one `.`, optional leading `-`).
private func isDecimalString(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    if bytes.isEmpty { return false }
    var index = 0
    if bytes[0] == 0x2d { index = 1 }
    var digits = 0
    var dots = 0
    while index < bytes.count {
        let b = bytes[index]
        if b >= 0x30 && b <= 0x39 { digits += 1 }
        else if b == 0x2e { dots += 1; if dots > 1 { return false } }
        else { return false }
        index += 1
    }
    return digits > 0
}

/// A pragmatic email check: exactly one `@`, a non-empty local part, and a domain with
/// a dot that is neither adjacent to the `@` nor at the end.
private func isValidEmailAddress(_ s: String) -> Bool {
    let b = Array(s.utf8)
    var at = -1
    for i in 0..<b.count where b[i] == 0x40 {   // '@'
        if at != -1 { return false }            // more than one '@'
        at = i
    }
    guard at > 0, at < b.count - 1 else { return false }   // local + something after '@'
    var dot = -1
    for i in (at + 1)..<b.count where b[i] == 0x2e {       // '.'
        dot = i
        break
    }
    return dot > at + 1 && dot < b.count - 1
}
