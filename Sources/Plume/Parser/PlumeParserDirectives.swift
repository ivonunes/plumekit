import Foundation

extension PlumeParser {
    mutating func parseStyle() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@style".count)
        index = skipInlineWhitespace(from: index)
        var file: String?
        var scoped = false

        if index < source.endIndex, source[index] == "(" {
            let arguments = try readParenthesizedExpressions()
            for argument in arguments {
                let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                if let separator = trimmed.firstIndex(of: ":") {
                    let label = String(trimmed[..<separator]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    let value = String(trimmed[trimmed.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    switch label {
                    case "file":
                        guard let string = quotedStyleArgument(value) else {
                            throw error("@style file must be a quoted path.", at: context)
                        }
                        file = string
                    case "scoped":
                        if value == "true" {
                            scoped = true
                        } else if value == "false" {
                            scoped = false
                        } else {
                            throw error("@style scoped must be true or false.", at: context)
                        }
                    default:
                        throw error("Unknown @style argument \(label).", at: context)
                    }
                } else if let string = quotedStyleArgument(trimmed) {
                    file = string
                } else if trimmed == "scoped" {
                    scoped = true
                } else if !trimmed.isEmpty {
                    throw error("Invalid @style argument \(trimmed).", at: context)
                }
            }
            index = skipInlineWhitespace(from: index)
        }

        if index < source.endIndex, source[index] == "{" {
            let css = try readRawBlock(named: "@style", context: context).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return .style(
                PlumeStyleDeclaration(
                    css: css, file: file, scoped: scoped, sourceName: sourceName, context: context))
        }

        _ = readLine()
        guard file != nil else {
            throw error("@style must include a CSS block or a file path.", at: context)
        }
        return .style(
            PlumeStyleDeclaration(
                css: nil, file: file, scoped: scoped, sourceName: sourceName, context: context))
    }

    mutating func parseScript() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@script".count)
        index = skipInlineWhitespace(from: index)
        var file: String?
        var explicitLanguage: PlumeScriptLanguage?
        var scoped = false

        if index < source.endIndex, source[index] == "(" {
            let arguments = try readParenthesizedExpressions()
            for argument in arguments {
                let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                if let separator = trimmed.firstIndex(of: ":") {
                    let label = String(trimmed[..<separator]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    let value = String(trimmed[trimmed.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    switch label {
                    case "file":
                        guard let string = quotedStyleArgument(value) else {
                            throw error("@script file must be a quoted path.", at: context)
                        }
                        file = string
                    case "language", "lang":
                        guard let string = quotedStyleArgument(value),
                            let parsed = parseScriptLanguage(string)
                        else {
                            throw error(
                                "@script language must be \"javascript\" or \"plume\".", at: context
                            )
                        }
                        explicitLanguage = parsed
                    case "scoped":
                        if value == "true" {
                            scoped = true
                        } else if value == "false" {
                            scoped = false
                        } else {
                            throw error("@script scoped must be true or false.", at: context)
                        }
                    default:
                        throw error("Unknown @script argument \(label).", at: context)
                    }
                } else if let string = quotedStyleArgument(trimmed) {
                    file = string
                } else if let parsed = parseScriptLanguage(trimmed) {
                    explicitLanguage = parsed
                } else if trimmed == "scoped" {
                    scoped = true
                } else if !trimmed.isEmpty {
                    throw error("Invalid @script argument \(trimmed).", at: context)
                }
            }
            index = skipInlineWhitespace(from: index)
        }

        let language = explicitLanguage ?? defaultScriptLanguage(file: file)

        if index < source.endIndex, source[index] == "{" {
            let js = try readRawBlock(named: "@script", context: context).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return .script(
                PlumeScriptDeclaration(
                    js: js, file: file, language: language, scoped: scoped, sourceName: sourceName,
                    context: context))
        }

        _ = readLine()
        guard file != nil else {
            throw error("@script must include a script block or a file path.", at: context)
        }
        return .script(
            PlumeScriptDeclaration(
                js: nil, file: file, language: language, scoped: scoped, sourceName: sourceName,
                context: context))
    }

    func defaultScriptLanguage(file: String?) -> PlumeScriptLanguage {
        guard let file else { return .plume }
        return file.lowercased().hasSuffix(".js") ? .javascript : .plume
    }

    func parseScriptLanguage(_ value: String) -> PlumeScriptLanguage? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "javascript", "js":
            .javascript
        case "plume", "client", "swift":
            .plume
        default:
            nil
        }
    }

    mutating func parseNavigation() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@navigation".count)
        index = skipInlineWhitespace(from: index)
        var root = "body"
        var viewTransitions = true
        var scroll = "top"
        var minimumDuration = 0
        var progressBar = true
        var progressBarDelay = 500

        if index < source.endIndex, source[index] == "(" {
            let arguments = try readParenthesizedExpressions()
            for argument in arguments {
                let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard let separator = topLevelIndex(of: ":", in: trimmed) else {
                    throw error("Invalid @navigation argument \(trimmed).", at: context)
                }
                let label = String(trimmed[..<separator]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                switch label {
                case "root":
                    guard let string = quotedStyleArgument(value), !string.isEmpty else {
                        throw error("@navigation root must be a quoted selector.", at: context)
                    }
                    root = string
                case "viewTransitions":
                    if value == "true" {
                        viewTransitions = true
                    } else if value == "false" {
                        viewTransitions = false
                    } else {
                        throw error(
                            "@navigation viewTransitions must be true or false.", at: context)
                    }
                case "scroll":
                    guard let string = quotedStyleArgument(value),
                        navigationScrollModes.contains(string)
                    else {
                        throw error(
                            "@navigation scroll must be \"top\", \"preserve\", or \"none\".",
                            at: context)
                    }
                    scroll = string
                case "minimumDuration":
                    guard let value = Int(value), value >= 0 else {
                        throw error(
                            "@navigation minimumDuration must be a non-negative integer.",
                            at: context)
                    }
                    minimumDuration = value
                case "progressBar":
                    if value == "true" {
                        progressBar = true
                    } else if value == "false" {
                        progressBar = false
                    } else {
                        throw error(
                            "@navigation progressBar must be true or false.", at: context)
                    }
                case "progressBarDelay":
                    guard let value = Int(value), value >= 0 else {
                        throw error(
                            "@navigation progressBarDelay must be a non-negative integer.",
                            at: context)
                    }
                    progressBarDelay = value
                default:
                    throw error("Unknown @navigation argument \(label).", at: context)
                }
            }
            index = skipInlineWhitespace(from: index)
        }

        let hooks: [PlumeNavigationHook]
        if index < source.endIndex, source[index] == "{" {
            let raw = try readRawBlock(named: "@navigation", context: context)
            hooks = try parseNavigationHooks(raw, context: context)
        } else {
            _ = readLine()
            hooks = []
        }

        return .navigation(
            PlumeNavigationDeclaration(
                resource: PlumeNavigationResource(
                    root: root, viewTransitions: viewTransitions, scroll: scroll,
                    minimumDuration: minimumDuration, progressBar: progressBar,
                    progressBarDelay: progressBarDelay, hooks: hooks),
                context: context
            ))
    }

    mutating func parseImage() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@image".count)
        index = skipInlineWhitespace(from: index)
        guard index < source.endIndex, source[index] == "(" else {
            throw error(
                "@image requires parentheses, for example @image(\"photo.jpg\", alt: \"\").",
                at: context)
        }
        let arguments = try parseComponentArguments(
            readParenthesizedExpressions(), context: context)
        return .image(PlumeImageDeclaration(arguments: arguments, context: context))
    }

    mutating func parseSlot() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@slot".count)
        index = skipInlineWhitespace(from: index)
        let name: String?
        if index < source.endIndex, source[index] == "(" {
            name = try parseSlotName(
                arguments: readParenthesizedExpressions(), context: context, required: false)
            index = skipInlineWhitespace(from: index)
        } else {
            name = nil
        }

        let fallback: [PlumeNode]
        if index < source.endIndex, source[index] == "{" {
            advance()
            fallback = try parseNodes(untilClosingBrace: true).nodes
        } else {
            fallback = []
        }
        return .slot(name: name, fallback: fallback, context: context)
    }

    mutating func parseContent() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@content".count)
        index = skipInlineWhitespace(from: index)
        guard index < source.endIndex, source[index] == "(" else {
            throw error(
                "@content requires a slot name, for example @content(header) { ... }.", at: context)
        }
        let name =
            try parseSlotName(
                arguments: readParenthesizedExpressions(), context: context, required: true) ?? ""
        index = skipInlineWhitespace(from: index)
        try consumeOpeningBrace(for: "@content")
        let body = try parseNodes(untilClosingBrace: true).nodes
        return .content(name: name, body: body, context: context)
    }

    mutating func parseState() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@state ".count)
        let declaration = readLine().trimmingCharacters(in: .whitespacesAndNewlines).trimmingSuffix(
            ";")
        guard let equals = declaration.firstIndex(of: "=") else {
            throw error("Invalid @state declaration.", at: context)
        }
        let name = String(declaration[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        else {
            throw error("Invalid @state name \(name).", at: context)
        }
        let expressionStart = declaration.index(after: equals)
        let expression = String(declaration[expressionStart...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return .state(name: name, expression: expression, context: context)
    }

    mutating func parseLet() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@let ".count)
        let declaration = readLine().trimmingCharacters(in: .whitespacesAndNewlines).trimmingSuffix(
            ";")
        guard let equals = declaration.firstIndex(of: "=") else {
            throw error("Invalid @let declaration.", at: context)
        }
        let name = String(declaration[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        else {
            throw error("Invalid @let name \(name).", at: context)
        }
        let expressionStart = declaration.index(after: equals)
        let expression = String(declaration[expressionStart...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return .assign(name: name, expression: expression, context: context)
    }

    mutating func parseConditional() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@if ".count)
        let condition = try readBlockHeader().trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try parseNodes(untilClosingBrace: true)
        guard body.closed else {
            throw error("Missing closing } for @if \(condition).", at: context)
        }

        let alternate = try parseConditionalContinuation()

        return .conditional(
            condition: condition, body: body.nodes, alternate: alternate, context: context)
    }

    mutating func parseConditionalAfterElseIf() throws -> PlumeNode {
        let context = sourceContext(at: index)
        let condition = try readBlockHeader().trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try parseNodes(untilClosingBrace: true)
        guard body.closed else {
            throw error("Missing closing } for else if \(condition).", at: context)
        }

        let alternate = try parseConditionalContinuation()

        return .conditional(
            condition: condition, body: body.nodes, alternate: alternate, context: context)
    }

    mutating func parseConditionalContinuation() throws -> [PlumeNode] {
        let afterBody = index
        let afterWhitespace = skipWhitespace(from: afterBody)
        guard consumeElseKeyword(at: afterWhitespace) else {
            return []
        }
        let afterElse = skipWhitespace(from: index)
        if source[afterElse...].hasPrefix("if ") {
            index = afterElse
            advance(by: "if ".count)
            return [try parseConditionalAfterElseIf()]
        }
        index = afterElse
        try consumeOpeningBrace(for: "else")
        return try parseNodes(untilClosingBrace: true).nodes
    }

    mutating func consumeElseKeyword(at start: String.Index) -> Bool {
        guard source[start...].hasPrefix("else") else { return false }
        let afterElse = source.index(start, offsetBy: "else".count)
        if afterElse < source.endIndex {
            let next = source[afterElse]
            guard !(next.isLetter || next.isNumber || next == "_" || next == "-") else {
                return false
            }
        }
        index = afterElse
        return true
    }

    mutating func parseLoop() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@for ".count)
        let header = try readBlockHeader()
        guard let inRange = header.range(of: #"\s+in\s+"#, options: .regularExpression) else {
            throw error("Invalid @for header \(header).", at: context)
        }
        let variable = String(header[..<inRange.lowerBound]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard variable.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        else {
            throw error("Invalid @for variable \(variable).", at: context)
        }
        let collection = String(header[inRange.upperBound...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let body = try parseNodes(untilClosingBrace: true)
        guard body.closed else {
            throw error("Missing closing } for @for \(variable).", at: context)
        }
        return .loop(variable: variable, collection: collection, body: body.nodes, context: context)
    }

    mutating func parseComponentDefinition() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance(by: "@component ".count)
        let signature = try readBlockHeader().trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try parseComponentSignature(signature, context: context)
        let body = try parseNodes(untilClosingBrace: true)
        guard body.closed else {
            throw error("Missing closing } for @component \(parsed.name).", at: context)
        }
        return .componentDefinition(
            PlumeComponent(
                name: parsed.name, parameters: parsed.parameters, body: body.nodes, context: context
            ))
    }

    mutating func parseComponentCall() throws -> PlumeNode {
        let context = sourceContext(at: index)
        advance()
        let name = readIdentifier()
        guard !name.isEmpty else {
            throw error("Invalid component call.", at: context)
        }
        index = skipWhitespace(from: index)
        guard index < source.endIndex, source[index] == "(" else {
            throw error(
                "Component calls must use parentheses, for example @\(name)().", at: context)
        }
        let arguments = try parseComponentArguments(
            readParenthesizedExpressions(), context: context)
        index = skipWhitespace(from: index)
        let body: [PlumeNode]
        if index < source.endIndex, source[index] == "{" {
            advance()
            body = try parseNodes(untilClosingBrace: true).nodes
        } else {
            body = []
        }
        return .componentCall(name: name, arguments: arguments, body: body, context: context)
    }
}
