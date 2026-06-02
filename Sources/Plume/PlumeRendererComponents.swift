import Foundation

extension PlumeRenderer {
    mutating func renderComponent(
        name: String, arguments: [PlumeArgument], body: [PlumeNode], context: PlumeSourceContext?
    ) throws -> PlumeFragment {
        guard let component = components[name] else {
            throw PlumeError.template(
                "Unknown Plume component: \(name).\(suggestion(for: name, in: Array(components.keys)))",
                context: context)
        }
        var scope = try componentScope(component, arguments: arguments, context: context)
        let slots = try renderSlots(from: body)
        let defaultSlot = slots["default"] ?? PlumeFragment()
        scope["slot"] = PlumeSafeHTML(
            addScopeAttributes(defaultSlot.html, scopes: defaultSlot.scopes))
        scope["slots"] = slots.mapValues {
            PlumeSafeHTML(addScopeAttributes($0.html, scopes: $0.scopes))
        }
        scopes.append(scope)
        defer { scopes.removeLast() }
        let componentFragment = try render(component.body)
        return PlumeFragment(
            html: addScopeAttributes(componentFragment.html, scopes: componentFragment.scopes),
            scopes: [])
    }

    mutating func componentScope(
        _ component: PlumeComponent, arguments: [PlumeArgument], context: PlumeSourceContext?
    ) throws -> [String: Any] {
        var scope: [String: Any] = [:]
        var positionalIndex = 0
        var named: [String: Any] = [:]
        let parameterNames = Set(component.parameters.map(\.name))

        for argument in arguments {
            let value = try evaluate(argument.expression, context: context) ?? NSNull()
            if let label = argument.label {
                guard parameterNames.contains(label) else {
                    throw PlumeError.template(
                        "Unknown argument \(label) for component \(component.name).\(suggestion(for: label, in: Array(parameterNames)))",
                        context: context)
                }
                if named[label] != nil {
                    throw PlumeError.template(
                        "Duplicate argument \(label) for component \(component.name).",
                        context: context)
                }
                if scope[label] != nil {
                    throw PlumeError.template(
                        "Duplicate argument \(label) for component \(component.name).",
                        context: context)
                }
                named[label] = value
                continue
            }
            guard positionalIndex < component.parameters.count else {
                throw PlumeError.template(
                    "Too many arguments for component \(component.name).", context: context)
            }
            scope[component.parameters[positionalIndex].name] = value
            positionalIndex += 1
        }

        for (name, value) in named {
            scope[name] = value
        }

        for parameter in component.parameters where scope[parameter.name] == nil {
            if let defaultExpression = parameter.defaultExpression {
                scopes.append(scope)
                let value: Any
                do {
                    defer { scopes.removeLast() }
                    value = try evaluate(defaultExpression, context: component.context) ?? NSNull()
                }
                scope[parameter.name] = value
            } else {
                scope[parameter.name] = NSNull()
            }
        }

        return scope
    }

    mutating func renderSlots(from body: [PlumeNode]) throws -> [String: PlumeFragment] {
        var defaultBody: [PlumeNode] = []
        var named: [String: [PlumeNode]] = [:]
        for node in body {
            if case .content(let name, let body, _) = node {
                named[name] = body
            } else {
                defaultBody.append(node)
            }
        }
        var slots: [String: PlumeFragment] = [:]
        slots["default"] = try render(defaultBody)
        for (name, body) in named {
            slots[name] = try render(body)
        }
        return slots
    }

    mutating func renderSlot(name: String?, fallback: [PlumeNode]) throws -> PlumeFragment {
        let key = name ?? "default"
        if let slots = resolve("slots") as? [String: PlumeSafeHTML],
            let slot = slots[key],
            !slot.html.isEmpty
        {
            return PlumeFragment(html: slot.html, scopes: [])
        }
        if key == "default", let slot = resolve("slot") as? PlumeSafeHTML, !slot.html.isEmpty {
            return PlumeFragment(html: slot.html, scopes: [])
        }
        return try render(fallback)
    }

    mutating func renderImage(_ declaration: PlumeImageDeclaration) throws -> PlumeFragment {
        let call = try evaluateFunctionArguments(
            declaration.arguments, evaluationContext: declaration.context)
        let rendered: Any?
        if let function = resolve("image") as? PlumeFunction {
            rendered = try function.call(call)
        } else {
            rendered = fallbackImage(call)
        }
        return PlumeFragment(html: stringify(rendered), scopes: [])
    }

    func fallbackImage(_ call: PlumeFunctionCall) -> PlumeSafeHTML {
        let firstArgument = call.arguments.isEmpty ? nil : call.arguments[0]
        let src = stringify(functionArgument(named: "src", in: call) ?? firstArgument ?? "")
        var attributes: [(String, String)] = [("src", src)]
        let alt = stringify(functionArgument(named: "alt", in: call) ?? "")
        attributes.append(("alt", alt))
        for name in [
            "width", "height", "sizes", "loading", "decoding", "fetchpriority", "fetchPriority",
            "class",
        ] {
            guard let value = functionArgument(named: name, in: call) else { continue }
            let attributeName = name == "fetchPriority" ? "fetchpriority" : name
            let rendered = stringify(value)
            guard !rendered.isEmpty else { continue }
            attributes.append((attributeName, rendered))
        }
        let html =
            attributes
            .map { #"\#($0.0)="\#(escapeHTML($0.1))""# }
            .joined(separator: " ")
        return PlumeSafeHTML("<img \(html)>")
    }

    func functionArgument(named name: String, in call: PlumeFunctionCall) -> Any? {
        guard let value = call.namedArguments[name] else { return nil }
        return value
    }
}
