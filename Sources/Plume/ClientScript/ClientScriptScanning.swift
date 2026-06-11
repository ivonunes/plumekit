import Foundation

extension ClientScriptCompiler {
    func topLevelAssignment(in expression: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        index = expression.index(after: index)
                    }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
            }
            if character == "=", depth == 0 {
                let previous =
                    index > expression.startIndex
                    ? expression[expression.index(before: index)] : " "
                let next =
                    expression.index(after: index) < expression.endIndex
                    ? expression[expression.index(after: index)] : " "
                if previous != "=" && previous != "!" && previous != "<" && previous != ">"
                    && next != "="
                {
                    return index
                }
            }
            index = expression.index(after: index)
        }
        return nil
    }

    func topLevelOpeningParenBeforeFinalClose(in expression: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var candidate: String.Index?
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        index = expression.index(after: index)
                    }
                    continue
                }
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
                if depth == 0 { candidate = index }
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 { return nil }
            }
            index = expression.index(after: index)
        }
        return depth == 0 ? candidate : nil
    }

    func lastTopLevelDot(in expression: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var result: String.Index?
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        index = expression.index(after: index)
                    }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
            }
            if character == ".", depth == 0 { result = index }
            index = expression.index(after: index)
        }
        return result
    }

    func topLevelColon(in expression: String) -> String.Index? {
        var quote: Character?
        var depth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        index = expression.index(after: index)
                    }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" || character == "[" || character == "{" { depth += 1 }
            if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
            }
            if character == ":", depth == 0 { return index }
            index = expression.index(after: index)
        }
        return nil
    }

    func splitArguments(_ expression: String) -> [String] {
        var output: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                current.append(character)
                if character == "\\" {
                    index = expression.index(after: index)
                    if index < expression.endIndex {
                        current.append(expression[index])
                    }
                } else if character == quoteCharacter {
                    quote = nil
                }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "(" || character == "[" || character == "{" {
                depth += 1
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == ")" || character == "]" || character == "}" {
                depth = max(0, depth - 1)
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == ",", depth == 0 {
                let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { output.append(value) }
                current = ""
                index = expression.index(after: index)
                continue
            }
            current.append(character)
            index = expression.index(after: index)
        }
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { output.append(value) }
        return output
    }

    func isIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    func isIdentifierPath(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"#,
            options: .regularExpression) != nil
    }

    func isQuoted(_ value: String) -> Bool {
        guard value.count >= 2, let first = value.first, let last = value.last else { return false }
        return (first == "\"" || first == "'") && first == last
    }

    func quoted(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func error(_ message: String, line: Int, sourceLine: String) -> PlumeError {
        PlumeError.template(
            message,
            context: PlumeSourceContext(
                sourceName: sourceName,
                line: max(1, line),
                column: 1,
                sourceLine: sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }
}
