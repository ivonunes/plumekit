import Foundation

enum PlumeExpressionInspector {
    static func assetReferences(in expression: String, context: PlumeSourceContext?) -> [PlumeAssetReference] {
        functionCalls(named: "asset", in: expression).map { call in
            let arguments = parseArguments(call)
            let pathExpression = arguments.first { $0.label == "path" }?.expression ?? arguments.first { $0.label == nil }?.expression ?? ""
            return PlumeAssetReference(
                path: literalString(pathExpression),
                expression: pathExpression,
                sourceName: context?.sourceName,
                context: context
            )
        }
    }

    static func imageSource(in arguments: [PlumeArgument]) -> String? {
        let expression = arguments.first { $0.label == "src" }?.expression ?? arguments.first { $0.label == nil }?.expression ?? ""
        return literalString(expression)
    }

    private static func functionCalls(named name: String, in expression: String) -> [String] {
        var calls: [String] = []
        var index = expression.startIndex
        while index < expression.endIndex {
            guard expression[index...].hasPrefix(name),
                  isIdentifierBoundary(before: index, in: expression) else {
                index = expression.index(after: index)
                continue
            }
            var cursor = expression.index(index, offsetBy: name.count)
            while cursor < expression.endIndex, expression[cursor].isWhitespace {
                cursor = expression.index(after: cursor)
            }
            guard cursor < expression.endIndex, expression[cursor] == "(",
                  let close = matchingParen(in: expression, open: cursor) else {
                index = expression.index(after: index)
                continue
            }
            let argumentStart = expression.index(after: cursor)
            calls.append(String(expression[argumentStart..<close]))
            index = expression.index(after: close)
        }
        return calls
    }

    private static func parseArguments(_ raw: String) -> [PlumeResourceArgument] {
        splitExpression(raw, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { argument in
                if let colon = topLevelIndex(of: ":", in: argument) {
                    return PlumeResourceArgument(
                        label: String(argument[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
                        expression: String(argument[argument.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                return PlumeResourceArgument(label: nil, expression: argument)
            }
    }

    private static func literalString(_ expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" || first == "'"),
              first == last else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func isIdentifierBoundary(before index: String.Index, in expression: String) -> Bool {
        guard index > expression.startIndex else { return true }
        let previous = expression[expression.index(before: index)]
        return !(previous.isLetter || previous.isNumber || previous == "_")
    }

    private static func matchingParen(in expression: String, open: String.Index) -> String.Index? {
        var index = expression.index(after: open)
        var depth = 1
        var quote: Character?
        var bracketDepth = 0
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex { index = expression.index(after: index) }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0, bracketDepth == 0 { return index }
            }
            index = expression.index(after: index)
        }
        return nil
    }

    private static func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
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
            } else if character == "(" {
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

    private static func splitExpression(_ expression: String, separator: String) -> [String] {
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
            } else if character == "(" {
                parenDepth += 1
                current.append(character)
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
            } else if character == "[" {
                bracketDepth += 1
                current.append(character)
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            } else if parenDepth == 0, bracketDepth == 0, expression[index...].hasPrefix(separator) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = expression.index(index, offsetBy: separator.count)
                continue
            } else {
                current.append(character)
            }
            index = expression.index(after: index)
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }
}
