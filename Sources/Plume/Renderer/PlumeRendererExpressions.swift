import Foundation

extension PlumeRenderer {
    static let splitExpressionCache = PlumeMemoCache<[String]>()
    static let comparisonCache = PlumeMemoCache<[String]?>()
    static let ternaryCache = PlumeMemoCache<[String]?>()

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
        let parts = Self.comparisonCache.value(for: expression) {
            for op in ["==", "!=", ">=", "<=", ">", "<"] {
                if let result = infix(expression, operatorText: op) {
                    return [result.left, op, result.right]
                }
            }
            return nil
        }
        guard let parts else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    func ternary(in expression: String) -> (
        condition: String, trueExpression: String, falseExpression: String
    )? {
        let parts = Self.ternaryCache.value(for: expression) {
            scanTernary(in: expression).map { [$0.condition, $0.trueExpression, $0.falseExpression] }
        }
        guard let parts else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    func scanTernary(in expression: String) -> (
        condition: String, trueExpression: String, falseExpression: String
    )? {
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0   // don't split on a `?`/`:` inside an array literal `[…]`
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
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == "?", parenDepth == 0, bracketDepth == 0 {
                question = index
            } else if character == ":", parenDepth == 0, bracketDepth == 0, let question {
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
        var bracketDepth = 0   // don't split on an operator inside an array literal `[…]`
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
            if character == "[" {
                bracketDepth += 1
                index = expression.index(after: index)
                continue
            }
            if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                index = expression.index(after: index)
                continue
            }
            if parenDepth == 0, bracketDepth == 0, expression[index...].hasPrefix(operatorText) {
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
        PlumeScanning.topLevelIndex(of: needle, in: expression)
    }

    func splitExpression(_ expression: String, separator: String) -> [String] {
        Self.splitExpressionCache.value(for: separator + "\u{1F}" + expression) {
            PlumeScanning.splitExpression(expression, separator: separator, skippingLogicalPipes: true)
        }
    }

    func quoted(_ expression: String) -> String? {
        guard expression.count >= 2, let quote = expression.first, quote == "\"" || quote == "'"
        else {
            return nil
        }
        var index = expression.index(after: expression.startIndex)
        while index < expression.endIndex {
            let character = expression[index]
            if character == "\\" {
                index = expression.index(after: index)
                if index < expression.endIndex { index = expression.index(after: index) }
                continue
            }
            if character == quote {
                guard expression.index(after: index) == expression.endIndex else { return nil }
                return String(expression.dropFirst().dropLast())
            }
            index = expression.index(after: index)
        }
        return nil
    }

    func escapeHTML(_ value: String) -> String {
        PlumeScanning.escapeHTML(value)
    }

    func escapeHTMLOnce(_ value: String) -> String {
        PlumeScanning.escapeHTMLOnce(value)
    }
}
