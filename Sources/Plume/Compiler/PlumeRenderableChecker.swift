//
//  PlumeRenderableChecker.swift
//  Plume — compiling back-end
//
//  Editor-grade checking of the *dynamically-renderable subset*: the features
//  that may appear in a template compiled for request-time rendering. It runs
//  before `swiftc` (fast, no code generation) and reports every out-of-subset
//  feature with a clear, source-located message naming the offender.
//
//  This is the Plume-level half of the two-layer model: it catches Plume mistakes
//  (build-time-only features, untyped props, build-time filters). Deep, member-
//  level type checking is still left to `swiftc` against the generated Swift.
//
//  The checker shares the generator's lowering for expressions, so the two never
//  disagree about what the compiling back-end accepts.
//

import Foundation

struct PlumeRenderableChecker {
    let components: [String: PlumeComponent]
    private let generator: PlumeSwiftGenerator
    private var diagnostics: [PlumeError] = []

    init(components: [String: PlumeComponent]) {
        self.components = components
        self.generator = PlumeSwiftGenerator(
            components: components, options: PlumeSwiftOptions(emitSourceLocations: false))
    }

    /// Returns every way `nodes` step outside the renderable subset. Empty means
    /// the template can be compiled.
    mutating func check(_ nodes: [PlumeNode]) -> [PlumeError] {
        diagnostics = []
        for node in nodes {
            switch node {
            case .componentDefinition(let component):
                checkComponent(component)
            case .text:
                continue
            default:
                // Renderable content must live inside an @component to have a
                // typed signature to lower into.
                if let context = nodeContext(node) {
                    record(
                        "Top-level content cannot be compiled. Wrap it in an @component so it has a typed signature.",
                        context)
                }
            }
        }
        return diagnostics
    }

    private mutating func checkComponent(_ component: PlumeComponent) {
        for parameter in component.parameters where (parameter.typeAnnotation ?? "").isEmpty {
            record(
                "Component \(component.name) parameter `\(parameter.name)` needs a Swift type to be compiled, e.g. `\(parameter.name): String`.",
                component.context)
        }
        checkNodes(component.body)
    }

    private mutating func checkNodes(_ nodes: [PlumeNode]) {
        for node in nodes {
            checkNode(node)
        }
    }

    private mutating func checkNode(_ node: PlumeNode) {
        switch node {
        case .text:
            return
        case .output(let expression, let context):
            let generator = self.generator  // local copy: don't capture self in the closure
            recordIfError(context) {
                _ = try generator.outputCall(expression, context: context)
            }
        case .conditional(let condition, let body, let alternate, let context):
            recordIfError(context) {
                if let binding = PlumeConditionParsing.optionalBinding(in: condition) {
                    _ = try PlumeSwiftExpression(context: context).lower(binding.expression)
                } else {
                    _ = try PlumeSwiftExpression(context: context).lowerCondition(condition)
                }
            }
            checkNodes(body)
            checkNodes(alternate)
        case .loop(_, let collection, let body, let context):
            recordIfError(context) {
                _ = try PlumeSwiftExpression(context: context).lower(collection)
            }
            checkNodes(body)
        case .assign(_, let expression, let context):
            recordIfError(context) {
                _ = try PlumeSwiftExpression(context: context).lower(expression)
            }
        case .componentCall(let name, let arguments, let body, let context):
            checkComponentCall(name: name, arguments: arguments, context: context)
            for node in body {
                if case .content(_, let contentBody, _) = node {
                    checkNodes(contentBody)
                } else {
                    checkNode(node)
                }
            }
        case .slot(_, let fallback, _):
            checkNodes(fallback)
        case .content(_, let body, let context):
            record("@content can only be used directly inside a component call.", context)
            checkNodes(body)
        case .componentDefinition(let component):
            checkComponent(component)
        case .state(_, let expression, let context):
            // @state lowers to a serialized hook; its initial value is an
            // expression computed from props, so it must be lowerable.
            recordIfError(context) {
                _ = try PlumeSwiftExpression(context: context).lower(expression)
            }
        case .style, .script, .navigation:
            // Compiled into the build-time bundle (CSS/JS) or a static marker; the
            // render function only emits the HTML-side hook.
            return
        case .image(let declaration):
            record(
                featureMessage("@image (the responsive-image asset pipeline is a build-time concern)"),
                declaration.context)
        }
    }

    private mutating func checkComponentCall(
        name: String, arguments: [PlumeArgument], context: PlumeSourceContext?
    ) {
        if components[name] == nil {
            record("Unknown Plume component: \(name).", context)
        }
        for argument in arguments {
            recordIfError(context) {
                _ = try PlumeSwiftExpression(context: context).lower(argument.expression)
            }
        }
    }

    /// Runs a piece of expression lowering and records any subset violation it
    /// raises, keeping the subset definition in one place (the generator). The
    /// lowering closure is evaluated by a non-mutating helper so it can read the
    /// shared generator without an exclusivity conflict.
    private mutating func recordIfError(
        _ context: PlumeSourceContext?, _ body: () throws -> Void
    ) {
        if let error = loweringError(context, body) {
            diagnostics.append(error)
        }
    }

    private func loweringError(
        _ context: PlumeSourceContext?, _ body: () throws -> Void
    ) -> PlumeError? {
        do {
            try body()
            return nil
        } catch let error as PlumeError {
            return PlumeError(message: error.message, context: error.context ?? context)
        } catch {
            return PlumeError.template("\(error)", context: context)
        }
    }

    private func featureMessage(_ feature: String) -> String {
        "\(feature) is a build-time feature and cannot be lowered into a request-time render function."
    }

    private mutating func record(_ message: String, _ context: PlumeSourceContext?) {
        diagnostics.append(PlumeError.template(message, context: context))
    }

    private func nodeContext(_ node: PlumeNode) -> PlumeSourceContext? {
        switch node {
        case .output(_, let context), .state(_, _, let context), .assign(_, _, let context),
            .loop(_, _, _, let context), .conditional(_, _, _, let context),
            .slot(_, _, let context), .content(_, _, let context),
            .componentCall(_, _, _, let context):
            return context
        case .style(let declaration): return declaration.context
        case .script(let declaration): return declaration.context
        case .navigation(let declaration): return declaration.context
        case .image(let declaration): return declaration.context
        case .componentDefinition(let component): return component.context
        case .text:
            return nil
        }
    }
}

extension PlumeTemplate {
    /// Every way this template steps outside the dynamically-renderable subset.
    /// Empty means it can be compiled by the back-end. This is fast and editor-
    /// grade; member-level type truth is still left to `swiftc`.
    public func renderableDiagnostics() -> [PlumeError] {
        var checker = PlumeRenderableChecker(components: components)
        return checker.check(nodes)
    }
}
