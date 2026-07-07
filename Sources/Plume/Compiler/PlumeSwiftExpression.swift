//
//  PlumeSwiftExpression.swift
//  Plume — compiling back-end
//
//  Lowers a Plume expression string to an equivalent Swift expression string.
//  The recursion order mirrors `PlumeRenderer.evaluate` so a given expression is
//  parsed into the same shape for both back-ends; only the emitted form differs.
//
//  Deep, member-level type checking is intentionally NOT done here — it is
//  deferred to `swiftc` against the generated code (the two-layer model). This
//  lowerer's job is purely structural: turn Plume syntax into Swift syntax.
//

import Foundation

struct PlumeSwiftExpression {
    var context: PlumeSourceContext?

    /// Lowers a value expression (no trailing `| filter` pipeline; the caller
    /// splits those off first).
    func lower(_ expression: String) throws -> String {
        var trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\"\"" }
        trimmed = PlumeSwiftScanning.stripOuterParentheses(trimmed)
        if trimmed.isEmpty { return "\"\"" }

        // Ternary (lowest precedence).
        if let ternary = PlumeSwiftScanning.scanTernary(in: trimmed) {
            let condition = try lowerCondition(ternary.condition)
            let whenTrue = try lower(ternary.trueExpression)
            let whenFalse = try lower(ternary.falseExpression)
            return "(\(condition) ? \(whenTrue) : \(whenFalse))"
        }

        // Literals that consume the whole expression.
        if let string = PlumeSwiftScanning.quoted(trimmed) {
            return swiftStringLiteral(fromPlumeInner: string)
        }
        if trimmed == "true" { return "true" }
        if trimmed == "false" { return "false" }
        if trimmed == "nil" || trimmed == "null" { return "nil" }
        if trimmed == "empty" || trimmed == "blank" { return "\"\"" }
        if let array = try arrayLiteral(trimmed) { return array }
        if isIntegerLiteral(trimmed) { return trimmed }
        if isDoubleLiteral(trimmed) { return trimmed }

        if let parts = PlumeSwiftScanning.infix(trimmed, operatorText: "||") {
            return "(\(try lowerCondition(parts.left)) || \(try lowerCondition(parts.right)))"
        }
        if let parts = PlumeSwiftScanning.infix(trimmed, operatorText: "&&") {
            return "(\(try lowerCondition(parts.left)) && \(try lowerCondition(parts.right)))"
        }
        // Comparisons. Equality routes through `Plume.equal` so string equality
        // is byte-wise (native `String ==` pulls in Unicode tables that fail to
        // LINK under Embedded). Comparisons against `nil` stay native (optional
        // presence checks are Embedded-safe). Ordering operators stay native and
        // are intended for numbers.
        if let comparison = comparison(in: trimmed) {
            let left = try lower(comparison.left)
            let right = try lower(comparison.right)
            switch comparison.op {
            case "==":
                if left == "nil" || right == "nil" { return "(\(left) == \(right))" }
                return "Plume.equal(\(left), \(right))"
            case "!=":
                if left == "nil" || right == "nil" { return "(\(left) != \(right))" }
                return "(!Plume.equal(\(left), \(right)))"
            default:
                return "(\(left) \(comparison.op) \(right))"
            }
        }

        // Nil-coalescing `a ?? b` (higher precedence than comparison, lower than a
        // primary; right-associative). Matches the interpreting renderer; `swiftc`
        // checks the left operand is actually optional.
        if let coalesce = PlumeSwiftScanning.infix(trimmed, operatorText: "??") {
            return "(\(try lower(coalesce.left)) ?? \(try lower(coalesce.right)))"
        }

        // Prefix `!` — Swift precedence: it binds tighter than comparison and
        // `??`, so it is recognised after them (`!a == b` is `(!a) == b`).
        if trimmed.hasPrefix("!") {
            return "(!\(try lowerCondition(String(trimmed.dropFirst()))))"
        }

        if let methodStart = firstMethodStart(in: trimmed) {
            return try lowerMethodChain(trimmed, methodStart: methodStart)
        }
        if let call = try functionCall(in: trimmed) {
            // `asset(path)` is allowed in compiled templates: it lowers to a call to the
            // app's generated `asset(_:)` (PlumeAssets.swift), so the same `asset("…")`
            // resolves the same content-hashed URL here as in the interpreter. Its argument
            // is lowered (Plume string literal → Swift), so escaping matches exactly.
            if call.name == "asset", let open = trimmed.firstIndex(of: "(") {
                let parsed = try readCallArguments(in: trimmed, from: open)
                if parsed.end == trimmed.endIndex, let path = parsed.values.first {
                    let stripped = stripArgumentLabel(path)
                    // The build resolves `asset("name")` to a baked URL literal, so the path
                    // must be a string literal (not a runtime expression).
                    guard stripped.hasPrefix("\"") || stripped.hasPrefix("'") else {
                        throw unsupported(
                            "asset(...) needs a string-literal path in a compiled template, e.g. asset(\"logo.png\").")
                    }
                    return "asset(\(try lower(stripped)))"
                }
            }
            // The runtime translation lookup. `{t("welcome.title")}` for a plain key, or
            // `{t("greeting", name: user.name)}` with placeholders — the `name: value`
            // pairs lower to the runtime's `[String: String]` params dictionary.
            if call.name == "t", let open = trimmed.firstIndex(of: "(") {
                let parsed = try readCallArguments(in: trimmed, from: open)
                if parsed.end == trimmed.endIndex, let key = parsed.values.first {
                    let loweredKey = try lower(stripArgumentLabel(key))
                    let rest = Array(parsed.values.dropFirst())
                    if rest.isEmpty { return "t(\(loweredKey))" }
                    var entries: [String] = []
                    for arg in rest {
                        let parts = PlumeSwiftScanning.splitTopLevel(arg, separator: ":")
                        guard parts.count >= 2 else {
                            throw unsupported("t(...) placeholders must be `name: value` pairs, e.g. t(\"greeting\", name: user.name).")
                        }
                        let label = parts[0].trimmingCharacters(in: .whitespaces)
                        let value = try lower(parts.dropFirst().joined(separator: ":"))
                        entries.append("\"\(label)\": \(value)")
                    }
                    return "t(\(loweredKey), [\(entries.joined(separator: ", "))])"
                }
            }
            return try lowerFunctionCall(name: call.name, arguments: call.arguments)
        }

        // A dotted member path: `post`, `post.title`, `items.0.name`.
        return try lowerMemberPath(trimmed)
    }

    /// Lowers an expression that is used in boolean position (`@if`, ternary
    /// condition, `&&`/`||`/`!` operand). The renderable subset requires these to
    /// be Swift `Bool`; if they are not, `swiftc` reports the mismatch at the
    /// originating `.plume` line.
    func lowerCondition(_ expression: String) throws -> String {
        try lower(expression)
    }

    // MARK: - Member paths

    func lowerMemberPath(_ path: String) throws -> String {
        let components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let first = components.first, isIdentifier(first) else {
            throw unsupported("Cannot lower expression to Swift: \(path)")
        }
        var output = first
        for raw in components.dropFirst() {
            let component = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = Int(component) {
                output += "[\(index)]"
            } else if component == "size" {
                // Plume's `.size`/`.count` both mean element count.
                output += ".count"
            } else if isIdentifier(component) {
                output += ".\(component)"
            } else {
                throw unsupported("Cannot lower member access `\(component)` in \(path)")
            }
        }
        return output
    }

    // MARK: - Arrays

    func arrayLiteral(_ expression: String) throws -> String? {
        guard expression.hasPrefix("["), expression.hasSuffix("]"),
            PlumeSwiftScanning.matchingOuterBrackets(expression)
        else {
            return nil
        }
        let inner = String(expression.dropFirst().dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return "[]" }
        let elements = try PlumeSwiftScanning.splitTopLevel(inner, separator: ",").map {
            try lower($0)
        }
        return "[\(elements.joined(separator: ", "))]"
    }

    // MARK: - Methods (Embedded-safe subset)

    func lowerMethodChain(_ expression: String, methodStart: String.Index) throws -> String {
        let baseExpression = String(expression[..<methodStart]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        var value = try lower(baseExpression)
        var cursor = methodStart
        while cursor < expression.endIndex {
            guard expression[cursor] == "." else {
                throw unsupported("Cannot lower method chain in expression: \(expression)")
            }
            cursor = expression.index(after: cursor)
            let nameStart = cursor
            while cursor < expression.endIndex,
                expression[cursor].isLetter || expression[cursor].isNumber
                    || expression[cursor] == "_"
            {
                cursor = expression.index(after: cursor)
            }
            let name = String(expression[nameStart..<cursor])
            while cursor < expression.endIndex, expression[cursor].isWhitespace {
                cursor = expression.index(after: cursor)
            }
            guard cursor < expression.endIndex, expression[cursor] == "(" else {
                throw unsupported("Invalid method call `\(name)` in expression: \(expression)")
            }
            let arguments = try readCallArguments(in: expression, from: cursor)
            cursor = arguments.end
            value = try applyMethod(name, arguments: arguments.values, base: value)
            while cursor < expression.endIndex, expression[cursor].isWhitespace {
                cursor = expression.index(after: cursor)
            }
        }
        return value
    }

    /// Lowers a single method application against an already-lowered base. Only
    /// the Embedded-safe predicate methods are supported; case-folding, regex,
    /// `replace`, `split`, `slugify` and friends are build-time-only and rejected.
    func applyMethod(_ name: String, arguments: [String], base: String) throws -> String {
        let lowered = try arguments.map { try lower($0) }
        func argument(_ index: Int) throws -> String {
            guard index < lowered.count else {
                throw unsupported("Method `\(name)` is missing an argument.")
            }
            return lowered[index]
        }
        switch name {
        case "hasPrefix", "startsWith":
            return "Plume.hasPrefix(\(base), \(try argument(0)))"
        case "hasSuffix", "endsWith":
            return "Plume.hasSuffix(\(base), \(try argument(0)))"
        case "contains":
            return "Plume.contains(\(base), \(try argument(0)))"
        default:
            throw unsupported(
                "The method `\(name)` is build-time-only (it relies on Foundation or Unicode) and is not available in the compiling back-end.")
        }
    }

    /// Reads a balanced `( ... )` argument list starting at `open`, returning the
    /// top-level comma-separated argument strings and the index just past `)`.
    func readCallArguments(in expression: String, from open: String.Index) throws -> (
        values: [String], end: String.Index
    ) {
        var cursor = expression.index(after: open)
        var arguments = ""
        var quote: Character?
        var depth = 0
        while cursor < expression.endIndex {
            let character = expression[cursor]
            if let quoteCharacter = quote {
                arguments.append(character)
                if character == quoteCharacter { quote = nil }
                cursor = expression.index(after: cursor)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                arguments.append(character)
                cursor = expression.index(after: cursor)
                continue
            }
            if character == "(" {
                depth += 1
                arguments.append(character)
                cursor = expression.index(after: cursor)
                continue
            }
            if character == ")" {
                if depth == 0 {
                    let values = PlumeSwiftScanning.splitTopLevel(arguments, separator: ",")
                        .filter { !$0.isEmpty }
                    return (values, expression.index(after: cursor))
                }
                depth -= 1
                arguments.append(character)
                cursor = expression.index(after: cursor)
                continue
            }
            arguments.append(character)
            cursor = expression.index(after: cursor)
        }
        throw unsupported("Missing closing ) in expression: \(expression)")
    }

    func lowerFunctionCall(name: String, arguments: [PlumeArgument]) throws -> String {
        throw unsupported(
            "The function `\(name)` is not available in the compiling back-end (it is a build-time helper).")
    }

    /// Drops a leading `label:` from an argument (e.g. `path: "x"` → `"x"`), leaving a
    /// string literal or ternary colon untouched.
    private func stripArgumentLabel(_ argument: String) -> String {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let label = trimmed[..<colon]
        guard let first = label.first, first.isLetter || first == "_",
              label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return trimmed }
        return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Comparison detection (mirrors renderer precedence)

    func comparison(in expression: String) -> (left: String, op: String, right: String)? {
        for op in ["==", "!=", ">=", "<=", ">", "<"] {
            if let result = PlumeSwiftScanning.infix(expression, operatorText: op) {
                return (result.left, op, result.right)
            }
        }
        return nil
    }

    /// First top-level `.name(` — the start of a method chain.
    func firstMethodStart(in expression: String) -> String.Index? {
        var quote: Character?
        var parenDepth = 0
        var cursor = expression.startIndex
        while cursor < expression.endIndex {
            let character = expression[cursor]
            if let quoteCharacter = quote {
                if character == quoteCharacter { quote = nil }
                cursor = expression.index(after: cursor)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                cursor = expression.index(after: cursor)
                continue
            }
            if character == "(" {
                parenDepth += 1
                cursor = expression.index(after: cursor)
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                cursor = expression.index(after: cursor)
                continue
            }
            if character == ".", parenDepth == 0 {
                var lookahead = expression.index(after: cursor)
                guard lookahead < expression.endIndex,
                    expression[lookahead].isLetter || expression[lookahead] == "_"
                else {
                    cursor = expression.index(after: cursor)
                    continue
                }
                while lookahead < expression.endIndex,
                    expression[lookahead].isLetter || expression[lookahead].isNumber
                        || expression[lookahead] == "_"
                {
                    lookahead = expression.index(after: lookahead)
                }
                var afterName = lookahead
                while afterName < expression.endIndex, expression[afterName].isWhitespace {
                    afterName = expression.index(after: afterName)
                }
                if afterName < expression.endIndex, expression[afterName] == "(" {
                    return cursor
                }
            }
            cursor = expression.index(after: cursor)
        }
        return nil
    }

    func functionCall(in expression: String) throws -> (name: String, arguments: [PlumeArgument])? {
        var cursor = expression.startIndex
        guard cursor < expression.endIndex, expression[cursor].isLetter || expression[cursor] == "_"
        else {
            return nil
        }
        let nameStart = cursor
        while cursor < expression.endIndex,
            expression[cursor].isLetter || expression[cursor].isNumber || expression[cursor] == "_"
        {
            cursor = expression.index(after: cursor)
        }
        let name = String(expression[nameStart..<cursor])
        while cursor < expression.endIndex, expression[cursor].isWhitespace {
            cursor = expression.index(after: cursor)
        }
        guard cursor < expression.endIndex, expression[cursor] == "(", expression.hasSuffix(")")
        else {
            return nil
        }
        return (name, [])
    }

    // MARK: - Literal helpers

    func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    func isIntegerLiteral(_ value: String) -> Bool {
        var digits = Substring(value)
        if digits.hasPrefix("-") { digits = digits.dropFirst() }
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber && $0.isASCII }
    }

    func isDoubleLiteral(_ value: String) -> Bool {
        Double(value) != nil
    }

    /// Converts the raw inner of a Plume string literal (Plume does not process
    /// escape sequences inside string literals) into a Swift string literal that
    /// reproduces the identical runtime bytes.
    func swiftStringLiteral(fromPlumeInner inner: String) -> String {
        var output = "\""
        for scalar in inner.unicodeScalars {
            switch scalar {
            case "\\": output += "\\\\"
            case "\"": output += "\\\""
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\0": output += "\\0"
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }

    func unsupported(_ message: String) -> PlumeError {
        PlumeError.template(message, context: context)
    }
}
