import Foundation

public struct PlumeSourceContext: Equatable, Sendable {
    public var sourceName: String?
    public var line: Int
    public var column: Int
    public var sourceLine: String

    public var description: String {
        let location = [sourceName, "\(line):\(column)"].compactMap { $0 }.joined(separator: ":")
        return sourceLine.isEmpty ? location : "\(location)\n\(sourceLine)\n\(String(repeating: " ", count: max(0, column - 1)))^"
    }
}

public struct PlumeError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var context: PlumeSourceContext?

    public static func template(_ message: String, context: PlumeSourceContext? = nil) -> PlumeError {
        PlumeError(message: message, context: context)
    }

    public var description: String {
        guard let context else { return message }
        return "\(message)\n\(context.description)"
    }

    func withContext(_ context: PlumeSourceContext?) -> PlumeError {
        guard self.context == nil else { return self }
        return PlumeError(message: message, context: context)
    }
}

public struct PlumeSafeHTML: Equatable, CustomStringConvertible {
    public var html: String

    public init(_ html: String) {
        self.html = html
    }

    public var description: String { html }
}

public struct PlumeFunctionCall {
    public var arguments: [Any?]
    public var namedArguments: [String: Any?]
    public var context: PlumeSourceContext?

    public init(arguments: [Any?], namedArguments: [String: Any?] = [:], context: PlumeSourceContext? = nil) {
        self.arguments = arguments
        self.namedArguments = namedArguments
        self.context = context
    }
}

public struct PlumeFunction {
    private let body: (PlumeFunctionCall) throws -> Any?

    public init(_ body: @escaping (PlumeFunctionCall) throws -> Any?) {
        self.body = body
    }

    public func call(_ call: PlumeFunctionCall) throws -> Any? {
        try body(call)
    }
}

public struct PlumeStyleResource: Equatable {
    public var css: String?
    public var file: String?
    public var scoped: Bool
    public var scope: String?
    public var sourceName: String?

    public init(css: String? = nil, file: String? = nil, scoped: Bool = false, scope: String? = nil, sourceName: String? = nil) {
        self.css = css
        self.file = file
        self.scoped = scoped
        self.scope = scope
        self.sourceName = sourceName
    }

    public var scopeAttribute: String? {
        guard let scope else { return nil }
        return "data-plume-scope-\(scope)"
    }
}

public enum PlumeScriptLanguage: String, Equatable {
    case javascript
    case plume
}

public struct PlumeScriptResource: Equatable {
    public var js: String?
    public var file: String?
    public var language: PlumeScriptLanguage
    public var scoped: Bool
    public var scope: String?
    public var sourceName: String?
    public var context: PlumeSourceContext?

    public init(js: String? = nil, file: String? = nil, language: PlumeScriptLanguage = .plume, scoped: Bool = false, scope: String? = nil, sourceName: String? = nil, context: PlumeSourceContext? = nil) {
        self.js = js
        self.file = file
        self.language = language
        self.scoped = scoped
        self.scope = scope
        self.sourceName = sourceName
        self.context = context
    }

    public var scopeAttribute: String? {
        guard let scope else { return nil }
        return "data-plume-scope-\(scope)"
    }
}

public struct PlumeNavigationHook: Equatable {
    public var name: String
    public var actions: [String]

    public init(name: String, actions: [String]) {
        self.name = name
        self.actions = actions
    }
}

public struct PlumeNavigationResource: Equatable {
    public var root: String
    public var viewTransitions: Bool
    public var scroll: String
    public var minimumDuration: Int
    public var hooks: [PlumeNavigationHook]

    public init(root: String = "body", viewTransitions: Bool = true, scroll: String = "top", minimumDuration: Int = 0, hooks: [PlumeNavigationHook] = []) {
        self.root = root
        self.viewTransitions = viewTransitions
        self.scroll = scroll
        self.minimumDuration = minimumDuration
        self.hooks = hooks
    }
}

public struct PlumeResourceArgument: Equatable {
    public var label: String?
    public var expression: String

    public init(label: String? = nil, expression: String) {
        self.label = label
        self.expression = expression
    }
}

public struct PlumeAssetReference: Equatable {
    public var path: String?
    public var expression: String
    public var sourceName: String?
    public var context: PlumeSourceContext?

    public init(path: String?, expression: String, sourceName: String? = nil, context: PlumeSourceContext? = nil) {
        self.path = path
        self.expression = expression
        self.sourceName = sourceName
        self.context = context
    }
}

public struct PlumeImageReference: Equatable {
    public var src: String?
    public var arguments: [PlumeResourceArgument]
    public var sourceName: String?
    public var context: PlumeSourceContext?

    public init(src: String?, arguments: [PlumeResourceArgument], sourceName: String? = nil, context: PlumeSourceContext? = nil) {
        self.src = src
        self.arguments = arguments
        self.sourceName = sourceName
        self.context = context
    }

    public var altExpression: String? {
        arguments.first { $0.label == "alt" }?.expression
    }
}

public struct PlumeRenderResult {
    public var html: String
    public var requiresRuntime: Bool
    public var state: [String: Any]
    public var styles: [PlumeStyleResource]
    public var scripts: [PlumeScriptResource]
    public var navigation: [PlumeNavigationResource]

    public init(html: String, requiresRuntime: Bool, state: [String: Any], styles: [PlumeStyleResource] = [], scripts: [PlumeScriptResource] = [], navigation: [PlumeNavigationResource] = []) {
        self.html = html
        self.requiresRuntime = requiresRuntime
        self.state = state
        self.styles = styles
        self.scripts = scripts
        self.navigation = navigation
    }
}

public struct PlumeCheckResult {
    public var styles: [PlumeStyleResource]
    public var scripts: [PlumeScriptResource]
    public var navigation: [PlumeNavigationResource]
    public var assets: [PlumeAssetReference]
    public var images: [PlumeImageReference]

    public init(styles: [PlumeStyleResource], scripts: [PlumeScriptResource] = [], navigation: [PlumeNavigationResource] = [], assets: [PlumeAssetReference] = [], images: [PlumeImageReference] = []) {
        self.styles = styles
        self.scripts = scripts
        self.navigation = navigation
        self.assets = assets
        self.images = images
    }
}
