import Foundation

public struct PlumeTemplate {
    private let nodes: [PlumeNode]
    private let components: [String: PlumeComponent]

    public init(_ source: String, sourceName: String? = nil, components componentSources: [String: String] = [:]) throws {
        try self.init(source, sourceName: sourceName, environment: PlumeTemplateEnvironment(componentSources: componentSources))
    }

    public init(_ source: String, sourceName: String? = nil, environment: PlumeTemplateEnvironment) throws {
        var parser = PlumeParser(source, sourceName: sourceName)
        let parsedNodes = try parser.parseTemplate()
        var definitions = environment.components
        for (componentName, component) in Self.collectComponents(from: parsedNodes) {
            definitions[componentName] = component
        }
        nodes = parsedNodes
        components = definitions
    }

    public func render(_ context: [String: Any]) throws -> String {
        try renderResult(context).html
    }

    public func renderResult(_ context: [String: Any]) throws -> PlumeRenderResult {
        var renderer = PlumeRenderer(context: context, components: components)
        return try renderer.renderDocument(nodes)
    }

    public func check() throws -> PlumeCheckResult {
        var checker = PlumeChecker(components: components)
        return try checker.check(nodes)
    }

    static func collectComponents(from nodes: [PlumeNode]) -> [String: PlumeComponent] {
        var components: [String: PlumeComponent] = [:]
        for node in nodes {
            switch node {
            case .componentDefinition(let component):
                components[component.name] = component
            case .conditional(_, let body, let alternate, _):
                components.merge(collectComponents(from: body)) { _, new in new }
                components.merge(collectComponents(from: alternate)) { _, new in new }
            case .loop(_, _, let body, _):
                components.merge(collectComponents(from: body)) { _, new in new }
            case .componentCall(_, _, let body, _):
                components.merge(collectComponents(from: body)) { _, new in new }
            case .slot(_, let fallback, _):
                components.merge(collectComponents(from: fallback)) { _, new in new }
            case .content(_, let body, _):
                components.merge(collectComponents(from: body)) { _, new in new }
            case .text, .output, .style, .script, .navigation, .image, .assign, .state:
                continue
            }
        }
        return components
    }
}

public struct PlumeTemplateEnvironment {
    let components: [String: PlumeComponent]

    public init(componentSources: [String: String] = [:]) throws {
        var definitions: [String: PlumeComponent] = [:]
        for (name, componentSource) in componentSources.sorted(by: Self.componentSourcePrecedence) {
            var componentParser = PlumeParser(componentSource, sourceName: name)
            let componentNodes = try componentParser.parseTemplate()
            let collected = PlumeTemplate.collectComponents(from: componentNodes)
            for (componentName, component) in collected {
                definitions[componentName] = component
            }
        }
        components = definitions
    }

    private static func componentSourcePrecedence(
        _ lhs: Dictionary<String, String>.Element,
        _ rhs: Dictionary<String, String>.Element
    ) -> Bool {
        let left = componentSourcePriority(lhs.key)
        let right = componentSourcePriority(rhs.key)
        if left != right {
            return left < right
        }
        return lhs.key < rhs.key
    }

    private static func componentSourcePriority(_ sourceName: String) -> Int {
        if sourceName.hasPrefix("DefaultTemplates/") || sourceName.hasPrefix("Docs/") {
            return 0
        }
        return 1
    }
}
