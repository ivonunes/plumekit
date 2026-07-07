//
//  PlumeSwiftScanning.swift
//  Plume — compiling back-end
//
//  Pure structural scanners over Plume expression strings, mirroring the grammar
//  the interpreting renderer recognises (see PlumeRendererExpressions). They are
//  duplicated here, rather than shared off `PlumeRenderer`, so the code generator
//  never depends on renderer state; behaviour is kept deliberately identical so a
//  template means the same thing to both back-ends.
//

import Foundation

enum PlumeSwiftScanning {
    /// Removes redundant outer parentheses, e.g. `((a + b))` -> `a + b`.
    static func stripOuterParentheses(_ expression: String) -> String {
        var output = expression
        while output.hasPrefix("("), output.hasSuffix(")"), matchingOuterParentheses(output) {
            output = String(output.dropFirst().dropLast()).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        return output
    }

    /// True when a leading `(` is closed only by the trailing `)` (so the whole
    /// expression is wrapped), not by an earlier `)`.
    static func matchingOuterParentheses(_ expression: String) -> Bool {
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

    /// True when the whole expression is a single bracketed array literal.
    static func matchingOuterBrackets(_ expression: String) -> Bool {
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

    /// Splits the lowest-precedence ternary `condition ? a : b`, honouring quotes
    /// and parentheses, matching the renderer's scanner.
    static func scanTernary(in expression: String) -> (
        condition: String, trueExpression: String, falseExpression: String
    )? {
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0
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
                let trueStart = expression.index(after: question)
                let trueExpression = String(expression[trueStart..<index]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let falseStart = expression.index(after: index)
                let falseExpression = String(expression[falseStart...]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return (condition, trueExpression, falseExpression)
            }
            index = expression.index(after: index)
        }
        return nil
    }

    /// Splits on the first top-level occurrence of `operatorText`.
    static func infix(_ expression: String, operatorText: String) -> (left: String, right: String)? {
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

    /// Returns the unquoted contents when the whole expression is a single quoted
    /// string literal (single or double quoted), else `nil`.
    static func quoted(_ expression: String) -> String? {
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

    static func splitTopLevel(_ expression: String, separator: String, skippingLogicalPipes: Bool = false)
        -> [String]
    {
        PlumeScanning.splitExpression(
            expression, separator: separator, skippingLogicalPipes: skippingLogicalPipes)
    }

    static func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
        PlumeScanning.topLevelIndex(of: needle, in: expression)
    }
}
