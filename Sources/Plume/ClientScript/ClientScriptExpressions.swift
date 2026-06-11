import Foundation

extension ClientScriptCompiler {
    func methodCall(in statement: String, lineNumber: Int, sourceLine: String) throws
        -> ClientScriptMethodCall?
    {
        guard statement.hasSuffix(")") else { return nil }
        guard let open = topLevelOpeningParenBeforeFinalClose(in: statement),
            let dot = lastTopLevelDot(in: String(statement[..<open]))
        else {
            return nil
        }
        let target = String(statement[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        let methodStart = statement.index(after: dot)
        let method = String(statement[methodStart..<open]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !target.isEmpty, isIdentifier(method) else {
            throw error(
                "Invalid Plume script method call.", line: lineNumber, sourceLine: sourceLine)
        }
        let argumentsStart = statement.index(after: open)
        let argumentsEnd = statement.index(before: statement.endIndex)
        let arguments = String(statement[argumentsStart..<argumentsEnd])
        return ClientScriptMethodCall(
            target: target, name: method, arguments: splitArguments(arguments).map(parseArgument))
    }

    func firstArgument(
        _ call: ClientScriptMethodCall, method: String, lineNumber: Int, sourceLine: String
    ) throws -> String {
        guard
            let expression = call.arguments.first(where: { $0.label == nil })?.expression
                ?? argument(named: "name", in: call)
                ?? argument(named: "class", in: call)
                ?? argument(named: "value", in: call)
        else {
            throw error("\(method) needs an argument.", line: lineNumber, sourceLine: sourceLine)
        }
        return expression
    }

    func argument(named name: String, in call: ClientScriptMethodCall) -> String? {
        call.arguments.first { $0.label == name }?.expression
    }

    func parseArgument(_ expression: String) -> ClientScriptArgument {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = topLevelColon(in: trimmed) {
            let label = String(trimmed[..<separator]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            if isIdentifier(label), !value.isEmpty {
                return ClientScriptArgument(label: label, expression: value)
            }
        }
        return ClientScriptArgument(label: nil, expression: trimmed)
    }

    func domTargetExpression(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "page" {
            return "(document.documentElement)"
        }
        if trimmed == "root" {
            return "(root)"
        }
        if isQuoted(trimmed) {
            return "(document.querySelector(\(trimmed)))"
        }
        return "(\(transformExpression(trimmed)))"
    }

    func transformExpression(_ expression: String) -> String {
        var output = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        output = replaceCall(in: output, pattern: #"\bpage\.queryAll\(([^()]*)\)"#) {
            "Array.from(document.querySelectorAll(\($0)))"
        }
        output = replaceCall(in: output, pattern: #"\bpage\.query\(([^()]*)\)"#) {
            "document.querySelector(\($0))"
        }
        output = replaceCall(in: output, pattern: #"\broot\.queryAll\(([^()]*)\)"#) {
            "Array.from(root.querySelectorAll(\($0)))"
        }
        output = replaceCall(in: output, pattern: #"\broot\.query\(([^()]*)\)"#) {
            "root.querySelector(\($0))"
        }
        output = output.replacingOccurrences(
            of: #"\bnil\b"#, with: "null", options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"\bpage\.scrollY\b"#, with: "window.scrollY", options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"\bpage\.scrollX\b"#, with: "window.scrollX", options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"\bpage\.width\b"#, with: "window.innerWidth", options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"\bpage\.height\b"#, with: "window.innerHeight", options: .regularExpression)
        output = output.replacingOccurrences(
            of: #"\bevent\.value\b"#, with: "event?.target?.value", options: .regularExpression)
        return output
    }

    func replaceCall(in expression: String, pattern: String, replacement: (String) -> String)
        -> String
    {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return expression }
        var output = expression
        let matches = regex.matches(
            in: output, range: NSRange(output.startIndex..<output.endIndex, in: output))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                let fullRange = Range(match.range(at: 0), in: output),
                let argumentRange = Range(match.range(at: 1), in: output)
            else { continue }
            output.replaceSubrange(fullRange, with: replacement(String(output[argumentRange])))
        }
        return output
    }
}
