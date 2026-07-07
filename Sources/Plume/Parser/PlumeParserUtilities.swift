import Foundation

extension PlumeParser {
    /// True when the literal so far ends inside an open tag with an unquoted attribute
    /// value about to be interpolated (`<a href=` → the next `{...}` is unquoted). Used
    /// to reject that form, since escaping can't make an unquoted value safe.
    func endsInUnquotedAttribute(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var lastLt = -1, lastGt = -1
        for i in bytes.indices {
            if bytes[i] == 0x3C { lastLt = i } else if bytes[i] == 0x3E { lastGt = i }
        }
        guard lastLt > lastGt else { return false }   // not inside an open tag
        var quote: UInt8 = 0
        var lastSignificant: UInt8 = 0
        var i = lastLt + 1
        while i < bytes.count {
            let b = bytes[i]
            if quote != 0 { if b == quote { quote = 0 } }
            else if b == 0x22 || b == 0x27 { quote = b }
            if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { lastSignificant = b }
            i += 1
        }
        return quote == 0 && lastSignificant == 0x3D   // ends with `=` outside a quote
    }

    func shouldParseOutputExpression(_ text: String) -> Bool {
        let next = source.index(after: index)
        guard next < source.endIndex else { return false }
        let character = source[next]
        guard character.isLetter || character.isNumber || character == "_" || character == "!" || character == "\"" || character == "'" || character == "-" else {
            return false
        }
        if (character == "\"" || character == "'") && !shouldParseQuotedOutputExpression() {
            return false
        }
        if character == "-" {
            let afterMinus = source.index(after: next)
            guard afterMinus < source.endIndex, source[afterMinus].isNumber else {
                return false
            }
        }
        guard index > source.startIndex else { return true }
        let previous = source[source.index(before: index)]
        // `-` is NOT a blocker: `id="{prefix}-{n}"` is common HTML-id composition
        // and the hyphen never legitimately precedes a block brace in CSS/JS.
        if !(previous.isLetter || previous.isNumber || previous == "_" || previous == "." || previous == "#" || previous == ")" || previous == "]") {
            return true
        }
        // The `{` is glued to a word character. That guard exists to keep CSS/JS
        // block braces (`selector{…}`, `){`) in raw <script>/<style> bodies and
        // prose literal — but a `{` inside a QUOTED ATTRIBUTE VALUE is
        // unambiguously an interpolation (`class="app-header{extraClass}"`), where
        // such braces never occur. So relax the guard there.
        return insideQuotedAttributeValue(text)
    }

    /// Whether `text` currently sits inside an OPEN quoted attribute value of an
    /// open tag (`<a class="…␣` with the quote still open). Mirrors the tag/quote
    /// scan in `endsInUnquotedAttribute`.
    func insideQuotedAttributeValue(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var lastLt = -1, lastGt = -1
        for i in bytes.indices {
            if bytes[i] == 0x3C { lastLt = i } else if bytes[i] == 0x3E { lastGt = i }
        }
        guard lastLt > lastGt else { return false }   // not inside an open tag
        var quote: UInt8 = 0
        var i = lastLt + 1
        while i < bytes.count {
            let b = bytes[i]
            if quote != 0 { if b == quote { quote = 0 } }
            else if b == 0x22 || b == 0x27 { quote = b }
            i += 1
        }
        return quote != 0   // still inside an open quoted attribute value
    }

    private func shouldParseQuotedOutputExpression() -> Bool {
        guard let candidate = bracedExpressionCandidate() else { return false }
        let expression = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expression.first == "\"" || expression.first == "'" else { return false }
        let pipe = topLevelIndex(of: "|", in: expression)
        let colon = topLevelIndex(of: ":", in: expression)
        if let colon, pipe == nil || colon < pipe! {
            return false
        }
        return true
    }

    private func bracedExpressionCandidate() -> String? {
        var cursor = source.index(after: index)
        var expression = ""
        var quote: Character?
        var parenDepth = 0
        while cursor < source.endIndex {
            let character = source[cursor]
            if let quoteCharacter = quote {
                expression.append(character)
                if character == quoteCharacter { quote = nil }
                cursor = source.index(after: cursor)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                expression.append(character)
                cursor = source.index(after: cursor)
                continue
            }
            if character == "(" {
                parenDepth += 1
                expression.append(character)
                cursor = source.index(after: cursor)
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                expression.append(character)
                cursor = source.index(after: cursor)
                continue
            }
            if character == "}", parenDepth == 0 {
                return expression
            }
            expression.append(character)
            cursor = source.index(after: cursor)
        }
        return nil
    }

    func shouldParseDirective(_ directive: String, allowingBlockBody: Bool) -> Bool {
        guard source[index...].hasPrefix(directive) else { return false }
        let after = source.index(index, offsetBy: directive.count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        if character == " " || character == "\t" || character == "\n" || character == "\r" || character == "(" {
            return true
        }
        return allowingBlockBody && character == "{"
    }

    func shouldParseSlotDirective() -> Bool {
        guard source[index...].hasPrefix("@slot") else { return false }
        let after = source.index(index, offsetBy: "@slot".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return !(character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    func shouldParseCSRFDirective() -> Bool {
        guard source[index...].hasPrefix("@csrf") else { return false }
        let after = source.index(index, offsetBy: "@csrf".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return !(character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    func shouldParseComponentCall() -> Bool {
        guard index < source.endIndex, source[index] == "@" else { return false }
        let next = source.index(after: index)
        guard next < source.endIndex, source[next].isUppercase else { return false }
        var cursor = next
        while cursor < source.endIndex, source[cursor].isLetter || source[cursor].isNumber || source[cursor] == "_" {
            cursor = source.index(after: cursor)
        }
        cursor = skipWhitespace(from: cursor)
        return cursor < source.endIndex && source[cursor] == "("
    }

    mutating func readIdentifier() -> String {
        let start = index
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "_" {
            advance()
        }
        return String(source[start..<index])
    }

    func splitExpression(_ expression: String, separator: String) -> [String] {
        PlumeScanning.splitExpression(expression, separator: separator)
    }

    func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
        PlumeScanning.topLevelIndex(of: needle, in: expression)
    }

    mutating func readLine() -> String {
        var line = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                advance()
                break
            }
            line.append(character)
            advance()
        }
        return line
    }

    func skipWhitespace(from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    func skipInlineWhitespace(from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\t" {
            cursor = source.index(after: cursor)
        }
        return cursor
    }

    func starts(with prefix: String) -> Bool {
        source[index...].hasPrefix(prefix)
    }

    func sourceContext(at location: String.Index) -> PlumeSourceContext {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let lineStart = lineStarts[low]
        let column = source.distance(from: lineStart, to: location) + 1
        var lineEnd = location
        while lineEnd < source.endIndex, source[lineEnd] != "\n" {
            lineEnd = source.index(after: lineEnd)
        }
        return PlumeSourceContext(sourceName: sourceName, line: low + 1, column: column, sourceLine: String(source[lineStart..<lineEnd]))
    }

    func error(_ message: String, at context: PlumeSourceContext? = nil) -> PlumeError {
        PlumeError.template(message, context: context ?? sourceContext(at: index))
    }

    mutating func advance() {
        index = source.index(after: index)
    }

    mutating func advance(by count: Int) {
        for _ in 0..<count where index < source.endIndex {
            advance()
        }
    }
}
