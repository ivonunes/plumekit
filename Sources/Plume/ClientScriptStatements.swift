import Foundation

extension ClientScriptCompiler {
    mutating func compile(line: String, rawLine: String, lineNumber: Int) throws {
        let statement =
            line.hasSuffix(";")
            ? String(line.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : line
        if statement == "}" {
            try closeBlock(lineNumber: lineNumber, sourceLine: rawLine)
            return
        }
        if statement == "} else {" {
            try closeForElse(lineNumber: lineNumber, sourceLine: rawLine)
            return
        }
        if statement.hasPrefix("on "), statement.hasSuffix("{") {
            try compileEvent(statement, lineNumber: lineNumber, sourceLine: rawLine)
            return
        }
        if statement.hasPrefix("if "), statement.hasSuffix("{") {
            let condition = String(statement.dropFirst(3).dropLast()).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !condition.isEmpty else {
                throw error(
                    "Plume script if blocks need a condition.", line: lineNumber,
                    sourceLine: rawLine)
            }
            emit("if (\(transformExpression(condition))) {")
            open(.normal)
            return
        }
        if statement.hasPrefix("for "), statement.hasSuffix("{") {
            try compileLoop(statement, lineNumber: lineNumber, sourceLine: rawLine)
            return
        }
        if statement.hasPrefix("let ") || statement.hasPrefix("var ") {
            try compileDeclaration(statement, lineNumber: lineNumber, sourceLine: rawLine)
            return
        }
        if let assignment = topLevelAssignment(in: statement) {
            let name = String(statement[..<assignment]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let valueStart = statement.index(after: assignment)
            let value = String(statement[valueStart...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard isIdentifierPath(name), !value.isEmpty else {
                throw error(
                    "Invalid Plume script assignment.", line: lineNumber, sourceLine: rawLine)
            }
            emit("\(transformExpression(name)) = \(transformExpression(value));")
            return
        }
        if statement.hasPrefix("return ") {
            let expression = String(statement.dropFirst(7)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            emit("return \(transformExpression(expression));")
            return
        }
        if let compiled = try compileMethodStatement(
            statement, lineNumber: lineNumber, sourceLine: rawLine)
        {
            emit(compiled)
            return
        }
        throw error(
            "Unsupported Plume script statement. Use @script(language: \"javascript\") for raw JavaScript.",
            line: lineNumber, sourceLine: rawLine)
    }

    mutating func compileDeclaration(_ statement: String, lineNumber: Int, sourceLine: String)
        throws
    {
        let keyword = statement.hasPrefix("let ") ? "let" : "var"
        let body = String(statement.dropFirst(keyword.count + 1)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let assignment = topLevelAssignment(in: body) else {
            throw error(
                "Plume script \(keyword) declarations need a value.", line: lineNumber,
                sourceLine: sourceLine)
        }
        let name = String(body[..<assignment]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = body.index(after: assignment)
        let value = String(body[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIdentifier(name), !value.isEmpty else {
            throw error(
                "Invalid Plume script \(keyword) declaration.", line: lineNumber,
                sourceLine: sourceLine)
        }
        emit("\(keyword == "let" ? "const" : "let") \(name) = \(transformExpression(value));")
    }

    mutating func compileLoop(_ statement: String, lineNumber: Int, sourceLine: String) throws {
        let body = String(statement.dropFirst(4).dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let range = body.range(of: " in ") else {
            throw error(
                "Plume script for loops use `for item in items { ... }`.", line: lineNumber,
                sourceLine: sourceLine)
        }
        let variable = String(body[..<range.lowerBound]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let collection = String(body[range.upperBound...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard isIdentifier(variable), !collection.isEmpty else {
            throw error("Invalid Plume script for loop.", line: lineNumber, sourceLine: sourceLine)
        }
        emit("for (const \(variable) of \(transformExpression(collection))) {")
        open(.normal)
    }

    mutating func compileEvent(_ statement: String, lineNumber: Int, sourceLine: String) throws {
        let body = String(statement.dropFirst(3).dropLast()).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let dot = lastTopLevelDot(in: body) else {
            throw error(
                "Plume script events use `on target.event { ... }`.", line: lineNumber,
                sourceLine: sourceLine)
        }
        let target = String(body[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        let event = String(body[body.index(after: dot)...]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !target.isEmpty, isIdentifier(event) else {
            throw error(
                "Invalid Plume script event declaration.", line: lineNumber, sourceLine: sourceLine)
        }

        if target == "page" {
            let eventName = event == "ready" ? "DOMContentLoaded" : event
            let receiver = event == "ready" ? "document" : "window"
            emit("\(receiver).addEventListener(\(quoted(eventName)), function(event) {")
            open(.eventSingle)
            return
        }

        if isQuoted(target) {
            emit("for (const element of document.querySelectorAll(\(target))) {")
            indent += 1
            emit("element.addEventListener(\(quoted(event)), function(event) {")
            indent += 1
            blocks.append(.eventSelector)
            return
        }

        emit("\(domTargetExpression(target))?.addEventListener(\(quoted(event)), function(event) {")
        open(.eventSingle)
    }

    mutating func compileMethodStatement(_ statement: String, lineNumber: Int, sourceLine: String)
        throws -> String?
    {
        guard
            let call = try methodCall(in: statement, lineNumber: lineNumber, sourceLine: sourceLine)
        else {
            return nil
        }
        if call.target == "page" {
            return try compilePageMethod(call, lineNumber: lineNumber, sourceLine: sourceLine)
        }
        if call.target == "event", call.name == "preventDefault", call.arguments.isEmpty {
            return "event.preventDefault();"
        }

        let target = domTargetExpression(call.target)
        switch call.name {
        case "addClass":
            let name = try firstArgument(
                call, method: "addClass", lineNumber: lineNumber, sourceLine: sourceLine)
            usesClassHelper = true
            return "\(target)?.classList.add(...__plumeClasses(\(transformExpression(name))));"
        case "removeClass":
            let name = try firstArgument(
                call, method: "removeClass", lineNumber: lineNumber, sourceLine: sourceLine)
            usesClassHelper = true
            return "\(target)?.classList.remove(...__plumeClasses(\(transformExpression(name))));"
        case "toggleClass":
            let name = try firstArgument(
                call, method: "toggleClass", lineNumber: lineNumber, sourceLine: sourceLine)
            if let force = argument(named: "when", in: call) ?? argument(named: "force", in: call) {
                return
                    "\(target)?.classList.toggle(\(transformExpression(name)), !!(\(transformExpression(force))));"
            }
            return "\(target)?.classList.toggle(\(transformExpression(name)));"
        case "setText":
            let value = try firstArgument(
                call, method: "setText", lineNumber: lineNumber, sourceLine: sourceLine)
            return
                "if (\(target)) \(target).textContent = String(\(transformExpression(value)) ?? \"\");"
        case "setAttribute":
            guard call.arguments.count >= 2 else {
                throw error(
                    "setAttribute needs a name and value.", line: lineNumber, sourceLine: sourceLine
                )
            }
            return
                "if (\(target)) \(target).setAttribute(\(transformExpression(call.arguments[0].expression)), String(\(transformExpression(call.arguments[1].expression)) ?? \"\"));"
        case "removeAttribute":
            let name = try firstArgument(
                call, method: "removeAttribute", lineNumber: lineNumber, sourceLine: sourceLine)
            return "\(target)?.removeAttribute(\(transformExpression(name)));"
        case "setStyle":
            guard call.arguments.count >= 2 else {
                throw error(
                    "setStyle needs a CSS property and value.", line: lineNumber,
                    sourceLine: sourceLine)
            }
            return
                "\(target)?.style.setProperty(\(transformExpression(call.arguments[0].expression)), String(\(transformExpression(call.arguments[1].expression)) ?? \"\"));"
        case "removeStyle":
            let name = try firstArgument(
                call, method: "removeStyle", lineNumber: lineNumber, sourceLine: sourceLine)
            return "\(target)?.style.removeProperty(\(transformExpression(name)));"
        case "focus", "blur":
            guard call.arguments.isEmpty else {
                throw error(
                    "\(call.name) does not take arguments.", line: lineNumber,
                    sourceLine: sourceLine)
            }
            return "\(target)?.\(call.name)();"
        default:
            throw error(
                "Unsupported Plume script method \(call.name).", line: lineNumber,
                sourceLine: sourceLine)
        }
    }

    mutating func compilePageMethod(
        _ call: ClientScriptMethodCall, lineNumber: Int, sourceLine: String
    ) throws -> String {
        switch call.name {
        case "addClass", "removeClass", "toggleClass":
            let elementCall = ClientScriptMethodCall(
                target: "page", name: call.name, arguments: call.arguments)
            let target = "(document.documentElement)"
            switch call.name {
            case "addClass":
                let name = try firstArgument(
                    elementCall, method: "addClass", lineNumber: lineNumber, sourceLine: sourceLine)
                usesClassHelper = true
                return "\(target)?.classList.add(...__plumeClasses(\(transformExpression(name))));"
            case "removeClass":
                let name = try firstArgument(
                    elementCall, method: "removeClass", lineNumber: lineNumber,
                    sourceLine: sourceLine)
                usesClassHelper = true
                return
                    "\(target)?.classList.remove(...__plumeClasses(\(transformExpression(name))));"
            default:
                let name = try firstArgument(
                    elementCall, method: "toggleClass", lineNumber: lineNumber,
                    sourceLine: sourceLine)
                if let force = argument(named: "when", in: elementCall)
                    ?? argument(named: "force", in: elementCall)
                {
                    return
                        "\(target)?.classList.toggle(\(transformExpression(name)), !!(\(transformExpression(force))));"
                }
                return "\(target)?.classList.toggle(\(transformExpression(name)));"
            }
        case "scrollToTop":
            let behavior = scrollBehaviorExpression(call)
            return "window.scrollTo({ top: 0, behavior: \(behavior) });"
        case "scrollTo":
            let behavior = scrollBehaviorExpression(call)
            if let selector = argument(named: "selector", in: call)
                ?? call.arguments.first?.expression
            {
                let block =
                    argument(named: "block", in: call).map(transformExpression) ?? quoted("start")
                let inline =
                    argument(named: "inline", in: call).map(transformExpression)
                    ?? quoted("nearest")
                return
                    "document.querySelector(\(transformExpression(selector)))?.scrollIntoView({ behavior: \(behavior), block: \(block), inline: \(inline) });"
            }
            let top = argument(named: "top", in: call) ?? argument(named: "y", in: call) ?? "0"
            return
                "window.scrollTo({ top: Number(\(transformExpression(top))), behavior: \(behavior) });"
        default:
            throw error(
                "Unsupported page method \(call.name).", line: lineNumber, sourceLine: sourceLine)
        }
    }

    func scrollBehaviorExpression(_ call: ClientScriptMethodCall) -> String {
        if let behavior = argument(named: "behavior", in: call) {
            return transformExpression(behavior)
        }
        if let smooth = argument(named: "smooth", in: call) {
            return "(\(transformExpression(smooth)) ? \"smooth\" : \"auto\")"
        }
        return quoted("auto")
    }
}
