import Foundation

struct PlumeComponent {
    var name: String
    var parameters: [PlumeParameter]
    var body: [PlumeNode]
    var context: PlumeSourceContext?
}

struct PlumeParameter {
    var name: String
    var defaultExpression: String?
    /// The Swift type named for the compiling back-end, e.g. `Post`, `[Post]`,
    /// `User?`. `nil` for templates that target only the interpreting renderer,
    /// which ignores the annotation. Member-level checking of the type is
    /// deferred to `swiftc` against the generated Swift, not reimplemented here.
    var typeAnnotation: String?
}

struct PlumeArgument {
    var label: String?
    var expression: String
}

struct PlumeStyleDeclaration {
    var css: String?
    var file: String?
    var scoped: Bool
    var sourceName: String?
    var context: PlumeSourceContext?
}

struct PlumeScriptDeclaration {
    var js: String?
    var file: String?
    var language: PlumeScriptLanguage
    var scoped: Bool
    var sourceName: String?
    var context: PlumeSourceContext?
}

struct PlumeNavigationDeclaration {
    var resource: PlumeNavigationResource
    var context: PlumeSourceContext?
}

struct PlumeImageDeclaration {
    var arguments: [PlumeArgument]
    var context: PlumeSourceContext?
}

enum PlumeNode {
    case text(String)
    case output(String, PlumeSourceContext?)
    case style(PlumeStyleDeclaration)
    case script(PlumeScriptDeclaration)
    case navigation(PlumeNavigationDeclaration)
    case image(PlumeImageDeclaration)
    case state(name: String, expression: String, context: PlumeSourceContext?)
    case assign(name: String, expression: String, context: PlumeSourceContext?)
    case loop(variable: String, collection: String, body: [PlumeNode], context: PlumeSourceContext?)
    case conditional(condition: String, body: [PlumeNode], alternate: [PlumeNode], context: PlumeSourceContext?)
    case slot(name: String?, fallback: [PlumeNode], context: PlumeSourceContext?)
    case content(name: String, body: [PlumeNode], context: PlumeSourceContext?)
    case componentDefinition(PlumeComponent)
    case componentCall(name: String, arguments: [PlumeArgument], body: [PlumeNode], context: PlumeSourceContext?)
}
