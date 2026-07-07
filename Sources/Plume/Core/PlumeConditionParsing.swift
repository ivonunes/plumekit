import Foundation

/// Shared parsing of condition headers, so the interpreting renderer and the
/// compiling back-end recognise the same forms with identical semantics.
enum PlumeConditionParsing {
    /// Recognises a Swift-style optional binding `let name = expression` (as used
    /// by `@if let name = expr { … }`). Returns `nil` for ordinary boolean
    /// conditions, including `let x == y` (a `==` is not a binding).
    static func optionalBinding(in condition: String) -> (name: String, expression: String)? {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("let ") else { return nil }
        let rest = trimmed.dropFirst("let ".count)
        guard let equals = PlumeScanning.topLevelIndex(of: "=", in: String(rest)) else {
            return nil
        }
        // Re-find the index in `rest` (topLevelIndex works on a fresh String).
        let restString = String(rest)
        let afterEquals = restString.index(after: equals)
        if afterEquals < restString.endIndex, restString[afterEquals] == "=" {
            return nil  // `==`, a comparison, not a binding
        }
        let name = String(restString[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = String(restString[afterEquals...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard
            name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
            !expression.isEmpty
        else {
            return nil
        }
        return (name, expression)
    }
}
