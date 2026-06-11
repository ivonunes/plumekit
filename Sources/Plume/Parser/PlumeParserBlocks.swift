import Foundation

extension PlumeParser {
    mutating func parseComment() throws {
        let context = sourceContext(at: index)
        advance(by: "@comment".count)
        index = skipWhitespace(from: index)
        try consumeOpeningBrace(for: "@comment")
        var depth = 1
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    advance()
                    return
                }
            }
            advance()
        }
        throw error("Missing closing } for @comment block.", at: context)
    }

    mutating func readRawBlock(named name: String, context: PlumeSourceContext?) throws -> String {
        guard index < source.endIndex, source[index] == "{" else {
            throw error("Missing opening { for \(name).", at: context)
        }
        advance()
        let start = index
        var depth = 1
        var quote: Character?
        var inComment = false
        var inLineComment = false
        while index < source.endIndex {
            let character = source[index]
            if inLineComment {
                if character == "\n" || character == "\r" {
                    inLineComment = false
                }
                advance()
                continue
            }
            if inComment {
                if character == "*", source.index(after: index) < source.endIndex,
                    source[source.index(after: index)] == "/"
                {
                    advance(by: 2)
                    inComment = false
                    continue
                }
                advance()
                continue
            }
            if let quoteCharacter = quote {
                if character == "\\" {
                    advance()
                    if index < source.endIndex { advance() }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                advance()
                continue
            }
            if character == "/", source.index(after: index) < source.endIndex,
                source[source.index(after: index)] == "/"
            {
                advance(by: 2)
                inLineComment = true
                continue
            }
            if character == "/", source.index(after: index) < source.endIndex,
                source[source.index(after: index)] == "*"
            {
                advance(by: 2)
                inComment = true
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                advance()
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = index
                    advance()
                    return String(source[start..<end])
                }
            }
            advance()
        }
        throw error("Missing closing } for \(name) block.", at: context)
    }

    mutating func readBlockHeader() throws -> String {
        var header = ""
        var quote: Character?
        var parenDepth = 0
        while index < source.endIndex {
            let character = source[index]
            if let quoteCharacter = quote {
                header.append(character)
                if character == quoteCharacter { quote = nil }
                advance()
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                header.append(character)
                advance()
                continue
            }
            if character == "(" {
                parenDepth += 1
                header.append(character)
                advance()
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                header.append(character)
                advance()
                continue
            }
            if character == "{", parenDepth == 0 {
                advance()
                return header
            }
            header.append(character)
            advance()
        }
        throw error("Missing opening { for Plume block.")
    }

    mutating func readBracedExpression() throws -> String {
        var expression = ""
        var quote: Character?
        var parenDepth = 0
        while index < source.endIndex {
            let character = source[index]
            if let quoteCharacter = quote {
                expression.append(character)
                if character == quoteCharacter { quote = nil }
                advance()
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                expression.append(character)
                advance()
                continue
            }
            if character == "(" {
                parenDepth += 1
                expression.append(character)
                advance()
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                expression.append(character)
                advance()
                continue
            }
            if character == "}", parenDepth == 0 {
                advance()
                return expression.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            expression.append(character)
            advance()
        }
        throw error("Missing closing } for Plume expression.")
    }

    mutating func consumeOpeningBrace(for directive: String) throws {
        guard index < source.endIndex, source[index] == "{" else {
            throw error("Missing opening { for \(directive).")
        }
        advance()
    }

    mutating func readParenthesizedExpressions() throws -> [String] {
        guard index < source.endIndex, source[index] == "(" else {
            throw error("Missing opening (.")
        }
        advance()
        var expression = ""
        var quote: Character?
        var parenDepth = 0
        while index < source.endIndex {
            let character = source[index]
            if let quoteCharacter = quote {
                expression.append(character)
                if character == quoteCharacter { quote = nil }
                advance()
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                expression.append(character)
                advance()
                continue
            }
            if character == "(" {
                parenDepth += 1
                expression.append(character)
                advance()
                continue
            }
            if character == ")" {
                if parenDepth == 0 {
                    advance()
                    return splitExpression(expression, separator: ",").filter { !$0.isEmpty }
                }
                parenDepth -= 1
                expression.append(character)
                advance()
                continue
            }
            expression.append(character)
            advance()
        }
        throw error("Missing closing ) in component call.")
    }

    func quotedStyleArgument(_ expression: String) -> String? {
        guard expression.count >= 2,
            let first = expression.first,
            let last = expression.last,
            first == "\"" || first == "'",
            first == last
        else {
            return nil
        }
        return String(expression.dropFirst().dropLast())
    }
}
