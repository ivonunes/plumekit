import Foundation

extension PlumeRenderer {
    func stripOuterParentheses(_ expression: String) -> String {
        var output = expression
        while output.hasPrefix("("), output.hasSuffix(")"), matchingOuterParentheses(output) {
            output = String(output.dropFirst().dropLast()).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        return output
    }

    func matchingOuterParentheses(_ expression: String) -> Bool {
        var depth = 0
        var quote: Character?
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
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0, expression.index(after: index) != expression.endIndex {
                    return false
                }
            }
            index = expression.index(after: index)
        }
        return depth == 0
    }

    func matchingOuterBrackets(_ expression: String) -> Bool {
        var depth = 0
        var quote: Character?
        var parenDepth = 0
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
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0, parenDepth == 0,
                    expression.index(after: index) != expression.endIndex
                {
                    return false
                }
            }
            index = expression.index(after: index)
        }
        return depth == 0
    }

    func comparison(in expression: String) -> (left: String, op: String, right: String)? {
        for op in ["==", "!=", ">=", "<=", ">", "<"] {
            if let result = infix(expression, operatorText: op) {
                return (result.left, op, result.right)
            }
        }
        return nil
    }

    func ternary(in expression: String) -> (
        condition: String, trueExpression: String, falseExpression: String
    )? {
        var quote: Character?
        var parenDepth = 0
        var question: String.Index?
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
            } else if character == "?", parenDepth == 0 {
                question = index
            } else if character == ":", parenDepth == 0, let question {
                let condition = String(expression[..<question]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let trueExpressionStart = expression.index(after: question)
                let trueExpression = String(expression[trueExpressionStart..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let falseExpressionStart = expression.index(after: index)
                let falseExpression = String(expression[falseExpressionStart...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (condition, trueExpression, falseExpression)
            }
            index = expression.index(after: index)
        }
        return nil
    }

    func infix(_ expression: String, operatorText: String) -> (left: String, right: String)? {
        var quote: Character?
        var parenDepth = 0
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
                index = expression.index(after: index)
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                index = expression.index(after: index)
                continue
            }
            if parenDepth == 0, expression[index...].hasPrefix(operatorText) {
                let left = String(expression[..<index]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let rightStart = expression.index(index, offsetBy: operatorText.count)
                let right = String(expression[rightStart...]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return (left, right)
            }
            index = expression.index(after: index)
        }
        return nil
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
            if parenDepth == 0, bracketDepth == 0, expression[index...].hasPrefix(separator),
                !isLogicalPipe(in: expression, at: index, separator: separator)
            {
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

    func isLogicalPipe(in expression: String, at index: String.Index, separator: String) -> Bool {
        guard separator == "|" else { return false }
        let next = expression.index(after: index)
        if next < expression.endIndex, expression[next] == "|" { return true }
        if index > expression.startIndex {
            let previous = expression.index(before: index)
            if expression[previous] == "|" { return true }
        }
        return false
    }

    func quoted(_ expression: String) -> String? {
        guard expression.count >= 2 else { return nil }
        if expression.first == "\"", expression.last == "\"" {
            return String(expression.dropFirst().dropLast())
        }
        if expression.first == "'", expression.last == "'" {
            return String(expression.dropFirst().dropLast())
        }
        return nil
    }

    func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func escapeHTMLOnce(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"&(?!(?:[A-Za-z]+|#[0-9]+|#x[0-9A-Fa-f]+);)"#, with: "&amp;",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
