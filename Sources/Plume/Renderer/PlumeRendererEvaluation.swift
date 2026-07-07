import Foundation

extension PlumeRenderer {
    mutating func renderOutput(_ expression: String, context: PlumeSourceContext?) throws -> String
    {
        let result = try evaluateExpression(expression, context: context)
        let value = stringify(result.value)
        let rendered = result.raw || isSafeHTML(result.value) ? value : escapeHTML(value)
        if let action = result.value as? PlumeAction {
            return registerBinding(
                expression: action.expression, rendered: action.expression, action: true)
        }
        if referencesState(expression) {
            return registerBinding(expression: expression, rendered: rendered, action: false)
        }
        return rendered
    }

    mutating func evaluateExpression(_ expression: String, context: PlumeSourceContext?) throws
        -> PlumeEvaluation
    {
        let previous = evaluationContext
        evaluationContext = context
        defer { evaluationContext = previous }
        return try evaluateExpression(expression)
    }

    mutating func evaluate(_ expression: String, context: PlumeSourceContext?) throws -> Any? {
        let previous = evaluationContext
        evaluationContext = context
        defer { evaluationContext = previous }
        return try evaluate(expression)
    }

    mutating func evaluateFunctionArguments(
        _ arguments: [PlumeArgument], evaluationContext context: PlumeSourceContext?
    ) throws -> PlumeFunctionCall {
        let previous = evaluationContext
        evaluationContext = context
        defer { evaluationContext = previous }
        return try evaluateFunctionArguments(arguments, context: context)
    }

    mutating func registerBinding(expression: String, rendered: String, action: Bool) -> String {
        let marker = "__PLUME_BINDING_\(nextBindingID)__"
        nextBindingID += 1
        bindings[marker] = PlumeBinding(expression: expression, rendered: rendered, action: action)
        return marker
    }

    mutating func evaluateExpression(_ expression: String) throws -> PlumeEvaluation {
        let segments = splitExpression(expression, separator: "|")
        guard let first = segments.first else {
            return PlumeEvaluation(value: "", raw: false)
        }
        var value = try evaluate(first)
        var raw = false
        for filter in segments.dropFirst() {
            let parsed = parseFilter(filter)
            if parsed.name == "raw" {
                raw = true
                continue
            }
            if parsed.name == "escape" {
                value = escapeHTML(stringify(value))
                raw = true
                continue
            }
            if parsed.name == "escape_once" {
                value = escapeHTMLOnce(stringify(value))
                raw = true
                continue
            }
            value = try applyFilter(parsed.name, arguments: parsed.arguments, to: value)
        }
        return PlumeEvaluation(value: value, raw: raw)
    }

    mutating func evaluate(_ expression: String) throws -> Any? {
        var trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        trimmed = stripOuterParentheses(trimmed)
        if let ternary = ternary(in: trimmed) {
            return try truthy(evaluate(ternary.condition))
                ? evaluate(ternary.trueExpression) : evaluate(ternary.falseExpression)
        }
        if let string = quoted(trimmed) { return string }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        if trimmed == "nil" || trimmed == "null" { return nil }
        if trimmed == "empty" || trimmed == "blank" { return "" }
        if let array = try arrayLiteral(trimmed) { return array }
        if let int = Int(trimmed) { return int }
        if let double = Double(trimmed) { return double }

        if let infix = infix(trimmed, operatorText: "||") {
            let left = truthy(try evaluate(infix.left))
            if left { return true }
            return truthy(try evaluate(infix.right))
        }
        if let infix = infix(trimmed, operatorText: "&&") {
            let left = truthy(try evaluate(infix.left))
            if !left { return false }
            return truthy(try evaluate(infix.right))
        }
        if let comparison = comparison(in: trimmed) {
            return try compare(
                left: evaluate(comparison.left), op: comparison.op,
                right: evaluate(comparison.right))
        }
        // Nil-coalescing `a ?? b`: like Swift, only nil/null coalesces (an empty
        // string is a value). Higher precedence than comparison, right-associative
        // (the right operand recurses). Identical to the compiling back-end's `??`.
        if let coalesce = infix(trimmed, operatorText: "??") {
            let left = try evaluate(coalesce.left)
            return isNilValue(left) ? try evaluate(coalesce.right) : left
        }
        // Prefix `!` binds tighter than comparison and `??` (Swift precedence), so
        // it is recognised after them: `!a == b` is `(!a) == b`.
        if trimmed.hasPrefix("!") {
            return !truthy(try evaluate(String(trimmed.dropFirst())))
        }
        if let value = try evaluateMethodChain(trimmed) {
            return value
        }
        if let call = try functionCall(in: trimmed) {
            return try evaluateFunctionCall(
                name: call.name, arguments: call.arguments, context: evaluationContext)
        }
        return resolve(trimmed)
    }

    mutating func arrayLiteral(_ expression: String) throws -> [Any?]? {
        guard expression.hasPrefix("["), expression.hasSuffix("]"),
            matchingOuterBrackets(expression)
        else {
            return nil
        }
        let inner = String(expression.dropFirst().dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return [] }
        return try splitExpression(inner, separator: ",").map { try evaluate($0) ?? NSNull() }
    }

    mutating func functionCall(in expression: String) throws -> (
        name: String, arguments: [PlumeArgument]
    )? {
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
        guard cursor < expression.endIndex, expression[cursor] == "(" else {
            return nil
        }
        let arguments = try readCallArguments(in: expression, from: cursor)
        var end = arguments.end
        while end < expression.endIndex, expression[end].isWhitespace {
            end = expression.index(after: end)
        }
        guard end == expression.endIndex else {
            return nil
        }
        return (name, try parseFunctionArguments(arguments.values))
    }

    mutating func evaluateFunctionCall(
        name: String, arguments: [PlumeArgument], context: PlumeSourceContext?
    ) throws -> Any? {
        guard let function = resolve(name) as? PlumeFunction else {
            throw PlumeError.template("Unsupported Plume function: \(name).", context: context)
        }
        return try function.call(evaluateFunctionArguments(arguments, context: context))
    }

    mutating func evaluateFunctionArguments(
        _ arguments: [PlumeArgument], context: PlumeSourceContext?
    ) throws -> PlumeFunctionCall {
        var positional: [Any?] = []
        var named: [String: Any?] = [:]
        for argument in arguments {
            let value = try evaluateExpression(argument.expression).value
            if let label = argument.label {
                named[label] = value
            } else {
                positional.append(value)
            }
        }
        return PlumeFunctionCall(arguments: positional, namedArguments: named, context: context)
    }

    mutating func evaluateMethodChain(_ expression: String) throws -> Any?? {
        guard let methodStart = firstMethodStart(in: expression) else { return nil }
        let baseExpression = String(expression[..<methodStart]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        if stateNames.contains(baseExpression),
            let action = try stateAction(expression: expression, from: methodStart)
        {
            return action
        }
        if let action = try browserAction(
            expression: expression, base: baseExpression, from: methodStart)
        {
            return action
        }
        var value = try evaluate(baseExpression)
        var cursor = methodStart
        while cursor < expression.endIndex {
            guard expression[cursor] == "." else {
                throw PlumeError.template("Invalid method chain in expression \(expression).")
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
                throw PlumeError.template(
                    "Invalid method call \(name) in expression \(expression).")
            }
            let arguments = try readCallArguments(in: expression, from: cursor)
            cursor = arguments.end
            value = try applyMethod(name, arguments: arguments.values, to: value)
            while cursor < expression.endIndex, expression[cursor].isWhitespace {
                cursor = expression.index(after: cursor)
            }
        }
        return value
    }

    mutating func stateAction(expression: String, from methodStart: String.Index) throws
        -> PlumeAction?
    {
        var cursor = methodStart
        guard cursor < expression.endIndex, expression[cursor] == "." else { return nil }
        cursor = expression.index(after: cursor)
        let nameStart = cursor
        while cursor < expression.endIndex,
            expression[cursor].isLetter || expression[cursor].isNumber || expression[cursor] == "_"
        {
            cursor = expression.index(after: cursor)
        }
        let name = String(expression[nameStart..<cursor])
        guard stateActionMethods.contains(name) else { return nil }
        while cursor < expression.endIndex, expression[cursor].isWhitespace {
            cursor = expression.index(after: cursor)
        }
        guard cursor < expression.endIndex, expression[cursor] == "(" else {
            throw PlumeError.template("Invalid state action \(name) in expression \(expression).")
        }
        let arguments = try readCallArguments(in: expression, from: cursor)
        guard arguments.end == expression.endIndex else {
            throw PlumeError.template("State action expressions must contain one action.")
        }
        return PlumeAction(expression: expression)
    }

    var stateActionMethods: Set<String> {
        ["toggle", "set", "increment", "decrement"]
    }

    mutating func browserAction(expression: String, base: String, from methodStart: String.Index)
        throws -> PlumeAction?
    {
        guard base == "page" else { return nil }
        var cursor = methodStart
        guard cursor < expression.endIndex, expression[cursor] == "." else { return nil }
        cursor = expression.index(after: cursor)
        let nameStart = cursor
        while cursor < expression.endIndex,
            expression[cursor].isLetter || expression[cursor].isNumber || expression[cursor] == "_"
        {
            cursor = expression.index(after: cursor)
        }
        let name = String(expression[nameStart..<cursor])
        guard browserActionMethods.contains(name) else { return nil }
        while cursor < expression.endIndex, expression[cursor].isWhitespace {
            cursor = expression.index(after: cursor)
        }
        guard cursor < expression.endIndex, expression[cursor] == "(" else {
            throw PlumeError.template("Invalid page action \(name) in expression \(expression).")
        }
        let arguments = try readCallArguments(in: expression, from: cursor)
        guard arguments.end == expression.endIndex else {
            throw PlumeError.template("Page action expressions must contain one action.")
        }
        let parsedArguments = try parseFunctionArguments(arguments.values)
        let allowedLabels = browserActionLabels[name] ?? []
        for argument in parsedArguments {
            guard let label = argument.label else { continue }
            guard allowedLabels.contains(label) else {
                throw PlumeError.template(
                    "Unknown argument \(label) for page.\(name)().\(suggestion(for: label, in: Array(allowedLabels)))"
                )
            }
        }
        return PlumeAction(expression: expression)
    }

    var browserActionMethods: Set<String> {
        ["addClass", "measure", "removeClass", "scrollTo", "scrollToTop", "toggleClass"]
    }

    var browserActionLabels: [String: Set<String>] {
        [
            "addClass": ["name", "class", "target"],
            "measure": ["target", "selector", "into", "properties", "round"],
            "removeClass": ["name", "class", "target"],
            "scrollTo": ["selector", "top", "y", "smooth", "behavior", "block", "inline"],
            "scrollToTop": ["smooth", "behavior"],
            "toggleClass": ["name", "class", "target", "force"],
        ]
    }

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

    mutating func readCallArguments(in expression: String, from open: String.Index) throws -> (
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
                    return (
                        splitExpression(arguments, separator: ",").filter { !$0.isEmpty },
                        expression.index(after: cursor)
                    )
                }
                depth -= 1
                arguments.append(character)
                cursor = expression.index(after: cursor)
                continue
            }
            arguments.append(character)
            cursor = expression.index(after: cursor)
        }
        throw PlumeError.template("Missing closing ) in expression \(expression).")
    }

    func parseFunctionArguments(_ rawArguments: [String]) throws -> [PlumeArgument] {
        var arguments: [PlumeArgument] = []
        var sawNamedArgument = false
        for rawArgument in rawArguments {
            let argument = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !argument.isEmpty else { continue }
            if let colon = topLevelIndex(of: ":", in: argument) {
                let label = String(argument[..<colon]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let expression = String(argument[argument.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    label.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression)
                        != nil
                else {
                    throw PlumeError.template("Invalid function argument label \(label).")
                }
                guard !expression.isEmpty else {
                    throw PlumeError.template("Missing value for function argument \(label).")
                }
                sawNamedArgument = true
                arguments.append(PlumeArgument(label: label, expression: expression))
            } else {
                if sawNamedArgument {
                    throw PlumeError.template(
                        "Positional function arguments must come before named arguments.")
                }
                arguments.append(PlumeArgument(label: nil, expression: argument))
            }
        }
        return arguments
    }
}
