import Foundation

struct PlumeChecker {
    private let components: [String: PlumeComponent]
    private var styles: [PlumeStyleResource] = []
    private var scripts: [PlumeScriptResource] = []
    private var navigation: [PlumeNavigationResource] = []
    private var assets: [PlumeAssetReference] = []
    private var images: [PlumeImageReference] = []

    init(components: [String: PlumeComponent]) {
        self.components = components
    }

    mutating func check(_ nodes: [PlumeNode]) throws -> PlumeCheckResult {
        try checkNodes(nodes)
        return PlumeCheckResult(styles: styles, scripts: scripts, navigation: navigation, assets: assets, images: images)
    }

    private mutating func checkNodes(_ nodes: [PlumeNode]) throws {
        for node in nodes {
            try checkNode(node)
        }
    }

    private mutating func checkNode(_ node: PlumeNode) throws {
        switch node {
        case .text, .assign, .state:
            return
        case .output(let expression, let context):
            assets.append(contentsOf: PlumeExpressionInspector.assetReferences(in: expression, context: context))
        case .image(let declaration):
            images.append(PlumeImageReference(
                src: PlumeExpressionInspector.imageSource(in: declaration.arguments),
                arguments: declaration.arguments.map { PlumeResourceArgument(label: $0.label, expression: $0.expression) },
                sourceName: declaration.context?.sourceName,
                context: declaration.context
            ))
        case .style(let declaration):
            styles.append(PlumeStyleResource(
                css: declaration.css,
                file: declaration.file,
                scoped: declaration.scoped,
                sourceName: declaration.sourceName
            ))
        case .script(let declaration):
            scripts.append(PlumeScriptResource(
                js: declaration.js,
                file: declaration.file,
                language: declaration.language,
                scoped: declaration.scoped,
                sourceName: declaration.sourceName,
                context: declaration.context
            ))
        case .navigation(let declaration):
            navigation.append(declaration.resource)
        case .loop(_, _, let body, _):
            try checkNodes(body)
        case .conditional(_, let body, let alternate, _):
            try checkNodes(body)
            try checkNodes(alternate)
        case .slot(_, let fallback, _):
            try checkNodes(fallback)
        case .content(_, _, let context):
            throw PlumeError.template("@content can only be used directly inside a component call.", context: context)
        case .componentDefinition(let component):
            try checkNodes(component.body)
        case .componentCall(let name, let arguments, let body, let context):
            try checkComponentCall(name: name, arguments: arguments, context: context)
            try checkComponentCallBody(body)
        }
    }

    private mutating func checkComponentCallBody(_ body: [PlumeNode]) throws {
        for node in body {
            if case .content(_, let contentBody, _) = node {
                try checkNodes(contentBody)
            } else {
                try checkNode(node)
            }
        }
    }

    private func checkComponentCall(name: String, arguments: [PlumeArgument], context: PlumeSourceContext?) throws {
        guard let component = components[name] else {
            throw PlumeError.template("Unknown Plume component: \(name).\(suggestion(for: name, in: Array(components.keys)))", context: context)
        }
        var positionalIndex = 0
        var assigned = Set<String>()
        let parameters = component.parameters.map(\.name)
        let parameterNames = Set(parameters)

        for argument in arguments {
            if let label = argument.label {
                guard parameterNames.contains(label) else {
                    throw PlumeError.template("Unknown argument \(label) for component \(component.name).\(suggestion(for: label, in: Array(parameterNames)))", context: context)
                }
                guard assigned.insert(label).inserted else {
                    throw PlumeError.template("Duplicate argument \(label) for component \(component.name).", context: context)
                }
            } else {
                guard positionalIndex < parameters.count else {
                    throw PlumeError.template("Too many arguments for component \(component.name).", context: context)
                }
                assigned.insert(parameters[positionalIndex])
                positionalIndex += 1
            }
        }
    }

    private func suggestion(for value: String, in candidates: [String]) -> String {
        PlumeScanning.suggestion(for: value, in: candidates)
    }
}
