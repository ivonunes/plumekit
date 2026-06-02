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

    func shouldParseStyleDirective() -> Bool {
        guard source[index...].hasPrefix("@style") else { return false }
        let after = source.index(index, offsetBy: "@style".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return character == " " || character == "\t" || character == "\n" || character == "\r" || character == "(" || character == "{"
    }

    func shouldParseScriptDirective() -> Bool {
        guard source[index...].hasPrefix("@script") else { return false }
        let after = source.index(index, offsetBy: "@script".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return character == " " || character == "\t" || character == "\n" || character == "\r" || character == "(" || character == "{"
    }

    func shouldParseNavigationDirective() -> Bool {
        guard source[index...].hasPrefix("@navigation") else { return false }
        let after = source.index(index, offsetBy: "@navigation".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return character == " " || character == "\t" || character == "\n" || character == "\r" || character == "(" || character == "{"
    }

    func shouldParseImageDirective() -> Bool {
        guard source[index...].hasPrefix("@image") else { return false }
        let after = source.index(index, offsetBy: "@image".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return character == " " || character == "\t" || character == "\n" || character == "\r" || character == "("
    }

    func shouldParseSlotDirective() -> Bool {
        guard source[index...].hasPrefix("@slot") else { return false }
        let after = source.index(index, offsetBy: "@slot".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return !(character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    func shouldParseContentDirective() -> Bool {
        guard source[index...].hasPrefix("@content") else { return false }
        let after = source.index(index, offsetBy: "@content".count)
        guard after < source.endIndex else { return true }
        let character = source[after]
        return character == " " || character == "\t" || character == "\n" || character == "\r" || character == "("
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
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                current.append(character)
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "(" {
                parenDepth += 1
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "[" {
                bracketDepth += 1
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if parenDepth == 0, bracketDepth == 0, expression[index...].hasPrefix(separator) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = expression.index(index, offsetBy: separator.count)
                continue
            }
            current.append(character)
            index = expression.index(after: index)
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == needle, parenDepth == 0, bracketDepth == 0 {
                return index
            }
            index = expression.index(after: index)
        }
        return nil
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
        var line = 1
        var column = 1
        var cursor = source.startIndex
        var lineStart = source.startIndex
        while cursor < location {
            if source[cursor] == "\n" {
                line += 1
                column = 1
                lineStart = source.index(after: cursor)
            } else {
                column += 1
            }
            cursor = source.index(after: cursor)
        }
        var lineEnd = location
        while lineEnd < source.endIndex, source[lineEnd] != "\n" {
            lineEnd = source.index(after: lineEnd)
        }
        return PlumeSourceContext(sourceName: sourceName, line: line, column: column, sourceLine: String(source[lineStart..<lineEnd]))
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
