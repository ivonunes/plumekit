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
        // Swift-style `"a \(x) b"` interpolation → a JS template literal, with each
        // interpolated expression transformed too. Done first so the rewrites below
        // see only real code (and skip the resulting `...` literal).
        output = convertInterpolatedStrings(output)
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
        // Token rewrites must NOT touch string-literal contents (`setText("Status: nil")`
        // must stay "nil", not become "null"), so apply them only outside strings.
        output = replaceOutsideStrings(output, of: #"\bnil\b"#, with: "null")
        output = replaceOutsideStrings(output, of: #"\bpage\.scrollY\b"#, with: "window.scrollY")
        output = replaceOutsideStrings(output, of: #"\bpage\.scrollX\b"#, with: "window.scrollX")
        output = replaceOutsideStrings(output, of: #"\bpage\.width\b"#, with: "window.innerWidth")
        output = replaceOutsideStrings(output, of: #"\bpage\.height\b"#, with: "window.innerHeight")
        output = replaceOutsideStrings(output, of: #"\bevent\.value\b"#, with: "event?.target?.value")
        return output
    }

    /// Apply a regex token replacement only to the code (non-string-literal) regions of
    /// `expression`, so a rewrite can't rewrite text inside a `"..."`/`'...'` literal.
    func replaceOutsideStrings(_ expression: String, of pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return expression }
        var result = ""
        var code = ""
        var quote: Character?
        func flushCode() {
            if code.isEmpty { return }
            result += regex.stringByReplacingMatches(
                in: code, range: NSRange(code.startIndex..<code.endIndex, in: code), withTemplate: template)
            code = ""
        }
        var i = expression.startIndex
        while i < expression.endIndex {
            let c = expression[i]
            if let q = quote {
                result.append(c)
                if c == "\\" {   // escape: pass the next char through verbatim too
                    let next = expression.index(after: i)
                    if next < expression.endIndex { result.append(expression[next]); i = expression.index(after: next); continue }
                } else if c == q {
                    quote = nil
                }
            } else if c == "\"" || c == "'" || c == "`" {
                flushCode(); quote = c; result.append(c)
            } else {
                code.append(c)
            }
            i = expression.index(after: i)
        }
        flushCode()
        return result
    }

    /// Convert each `"...\(expr)..."` (or single-quoted) literal to a JS template
    /// literal `` `...${expr}...` ``, transforming the interpolated `expr`. Literals
    /// with no interpolation are left untouched.
    func convertInterpolatedStrings(_ expression: String) -> String {
        var result = ""
        var i = expression.startIndex
        while i < expression.endIndex {
            let c = expression[i]
            guard c == "\"" || c == "'" else { result.append(c); i = expression.index(after: i); continue }
            // Scan the whole literal, respecting `\` escapes AND `\(…)` interpolation
            // regions (whose inner quotes must not be mistaken for the closing quote).
            var body = ""
            var j = expression.index(after: i)
            var closed = false
            while j < expression.endIndex {
                let ch = expression[j]
                let next = expression.index(after: j)
                if ch == "\\", next < expression.endIndex, expression[next] == "(",
                   let close = matchingParen(expression, from: expression.index(after: next)) {
                    body += expression[j...close]              // append `\(…)` whole
                    j = expression.index(after: close)
                    continue
                }
                if ch == "\\" {
                    body.append(ch)
                    if next < expression.endIndex { body.append(expression[next]); j = expression.index(after: next); continue }
                } else if ch == c {
                    closed = true; j = expression.index(after: j); break
                }
                body.append(ch)
                j = expression.index(after: j)
            }
            if !closed { result.append(c); i = expression.index(after: i); continue }   // unterminated: leave be
            result += convertStringBody(body)
            i = j
        }
        return result
    }

    /// The literal body (no delimiters) → the original `"..."` if it has no `\(`, else a
    /// backtick template literal with `${transformedExpr}` holes.
    private func convertStringBody(_ body: String) -> String {
        if !body.contains("\\(") { return "\"" + body + "\"" }
        var out = "`"
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == "\\", body.index(after: i) < body.endIndex, body[body.index(after: i)] == "(" {
                let exprStart = body.index(i, offsetBy: 2)
                guard let close = matchingParen(body, from: exprStart) else {
                    out.append(c); i = body.index(after: i); continue
                }
                out += "${" + transformExpression(String(body[exprStart..<close])) + "}"
                i = body.index(after: close)
            } else if c == "`" { out += "\\`"; i = body.index(after: i) }
            else if c == "$" { out += "\\$"; i = body.index(after: i) }
            else if c == "\\" {                       // keep other escapes (\n, \", …)
                out.append(c)
                let n = body.index(after: i)
                if n < body.endIndex { out.append(body[n]); i = body.index(after: n) } else { i = n }
            } else { out.append(c); i = body.index(after: i) }
        }
        return out + "`"
    }

    /// Index of the `)` matching the interpolation's opening paren, tracking nesting and
    /// string literals; nil if unbalanced.
    private func matchingParen(_ s: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var quote: Character?
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == "\\" { i = s.index(after: i); if i < s.endIndex { i = s.index(after: i) }; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
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
