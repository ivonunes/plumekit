//
//  PlumeSwiftBackend.swift
//  Plume — compiling back-end
//
//  Public entry points for lowering Plume templates to Embedded-Swift-clean Swift
//  source. This is the second back-end: it reuses the entire existing front-end
//  (lexer, parser, AST) unchanged and only adds a code generator over the AST.
//

import Foundation

public enum PlumeSwiftBackend {
    /// Parses `source` and emits Swift `render` functions for every `@component`
    /// it declares. `componentSources` provides any components referenced but
    /// defined elsewhere (so calls can be lowered to typed function calls).
    public static func generate(
        source: String,
        sourceName: String? = nil,
        componentSources: [String: String] = [:],
        options: PlumeSwiftOptions = PlumeSwiftOptions()
    ) throws -> String {
        var desugared: [String: String] = [:]
        for (name, componentSource) in componentSources {
            desugared[name] = PlumeCompiledDesugar.desugar(componentSource)
        }
        let environment = try PlumeTemplateEnvironment(componentSources: desugared)
        let template = try PlumeTemplate(
            PlumeCompiledDesugar.desugar(source), sourceName: sourceName, environment: environment)
        return try template.compileToSwift(options: options)
    }
}

extension PlumeTemplate {
    /// Lowers this template's components to Swift source targeting `PlumeRuntime`.
    public func compileToSwift(options: PlumeSwiftOptions = PlumeSwiftOptions()) throws -> String {
        var generator = PlumeSwiftGenerator(components: components, options: options)
        return try generator.generate(topLevel: nodes)
    }
}
