import Foundation

extension PlumeParser {
    func parseComponentSignature(_ signature: String, context: PlumeSourceContext?) throws -> (
        name: String, parameters: [PlumeParameter]
    ) {
        guard let open = signature.firstIndex(of: "("), signature.last == ")" else {
            throw error("Invalid @component signature \(signature).", at: context)
        }
        let name = String(signature[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: #"^[A-Z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw error(
                "Component names should use UpperCamelCase, for example PostCard.", at: context)
        }
        let parametersStart = signature.index(after: open)
        let parameterText = String(
            signature[parametersStart..<signature.index(before: signature.endIndex)])
        let parameters = try splitExpression(parameterText, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { parameter throws -> PlumeParameter in
                // A parameter is `name`, `name = default`, `name: Type`, or
                // `name: Type = default`. Split the default off first (top-level
                // `=`), then split an optional Swift type annotation off the head
                // (top-level `:`, which correctly ignores colons inside a
                // dictionary type such as `[String: Int]`).
                var head = parameter
                var defaultExpression: String?
                if let equals = topLevelIndex(of: "=", in: parameter) {
                    head = String(parameter[..<equals]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    let expression = String(parameter[parameter.index(after: equals)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !expression.isEmpty else {
                        throw error(
                            "Missing default value for component parameter \(head).", at: context)
                    }
                    defaultExpression = expression
                }

                var name = head
                var typeAnnotation: String?
                if let colon = topLevelIndex(of: ":", in: head) {
                    name = String(head[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let type = String(head[head.index(after: colon)...]).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    guard !type.isEmpty else {
                        throw error(
                            "Missing Swift type for component parameter \(name).", at: context)
                    }
                    typeAnnotation = type
                }

                try validateComponentParameter(name, context: context)
                return PlumeParameter(
                    name: name, defaultExpression: defaultExpression, typeAnnotation: typeAnnotation)
            }
        let duplicates = Dictionary(grouping: parameters, by: \.name).filter { $0.value.count > 1 }
            .keys
        if let duplicate = duplicates.first {
            throw error("Duplicate component parameter \(duplicate).", at: context)
        }
        return (name, parameters)
    }

    func validateComponentParameter(_ parameter: String, context: PlumeSourceContext?) throws {
        guard parameter.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        else {
            throw error("Invalid component parameter \(parameter).", at: context)
        }
    }

    func parseComponentArguments(_ rawArguments: [String], context: PlumeSourceContext?) throws
        -> [PlumeArgument]
    {
        var arguments: [PlumeArgument] = []
        var sawNamedArgument = false
        for rawArgument in rawArguments {
            let argument = rawArgument.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !argument.isEmpty else { continue }
            if let colon = topLevelIndex(of: ":", in: argument) {
                let label = String(argument[..<colon]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let expression = String(argument[argument.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    label.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression)
                        != nil
                else {
                    throw error("Invalid component argument label \(label).", at: context)
                }
                guard !expression.isEmpty else {
                    throw error("Missing value for component argument \(label).", at: context)
                }
                sawNamedArgument = true
                arguments.append(PlumeArgument(label: label, expression: expression))
            } else {
                if sawNamedArgument {
                    throw error(
                        "Positional component arguments must come before named arguments.",
                        at: context)
                }
                arguments.append(PlumeArgument(label: nil, expression: argument))
            }
        }
        return arguments
    }

    func parseSlotName(arguments: [String], context: PlumeSourceContext?, required: Bool) throws
        -> String?
    {
        guard let first = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty
        else {
            if required {
                throw error("Slot name is required.", at: context)
            }
            return nil
        }
        guard arguments.count == 1 else {
            throw error("Slots accept one name argument.", at: context)
        }
        let value: String
        if let colon = topLevelIndex(of: ":", in: first) {
            let label = String(first[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard label == "name" else {
                throw error("Unknown slot argument \(label).", at: context)
            }
            value = String(first[first.index(after: colon)...]).trimmingCharacters(
                in: .whitespacesAndNewlines)
        } else {
            value = first
        }
        if let quoted = quotedStyleArgument(value) {
            return quoted
        }
        guard value.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
        else {
            throw error("Invalid slot name \(value).", at: context)
        }
        return value
    }
}
