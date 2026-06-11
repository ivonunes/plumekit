import Foundation

extension PlumeParser {
    func shouldParseOutputExpression() -> Bool {
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
        return !(previous.isLetter || previous.isNumber || previous == "_" || previous == "-" || previous == "." || previous == "#" || previous == ")" || previous == "]")
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
