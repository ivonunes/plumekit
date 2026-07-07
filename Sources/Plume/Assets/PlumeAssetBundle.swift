//
//  PlumeAssetBundle.swift
//  Plume — build-time asset pipeline
//
//  At BUILD time (full toolchain, never Embedded, never in a guest) this compiles
//  a template set's `@style` (scoped CSS) and `@script` (client-script language →
//  JS) plus the Plume client runtime into a single, content-hashed static asset
//  bundle. Render functions emit only the HTML-side hooks (scope attributes,
//  serialized initial `@state`, navigation markers); the heavy CSS/JS lives here.
//
//  Scope ids come from `PlumeScope`, the same definition the compiling back-end
//  uses for the scope attribute it writes into the HTML, so the bundled CSS and
//  the markup always match.
//
//  Plume only PRODUCES the bundle (in memory, or written to disk). Serving it,
//  fingerprint routing, and cache headers are not Plume's concern.
//

import Foundation

public struct PlumeAssetBundle {
    /// The concatenated, scope-rewritten stylesheet.
    public let css: String
    /// The client runtime plus every compiled `@script`.
    public let javaScript: String
    /// Content-hashed file name for the stylesheet, e.g. `app.<hash>.css`.
    public let cssFileName: String
    /// Content-hashed file name for the script, e.g. `app.<hash>.js`.
    public let javaScriptFileName: String

    /// Logical name → hashed file name (`"app.css" → "app.<hash>.css"`).
    public var manifest: [String: String] {
        ["app.css": cssFileName, "app.js": javaScriptFileName]
    }

    /// Builds a bundle from `templates` (source keyed by name). `fileResolver`
    /// resolves `@style(file:)` / `@script(file:)` paths to contents; when nil,
    /// file-backed declarations are skipped (the host owns the filesystem).
    public static func build(
        templates: [String: String],
        includeRuntime: Bool = true,
        fileResolver: ((String) -> String?)? = nil
    ) throws -> PlumeAssetBundle {
        var styles: [String] = []
        var scripts: [String] = []

        for name in templates.keys.sorted() {
            let source = templates[name] ?? ""
            var parser = PlumeParser(source, sourceName: name)
            let nodes = try parser.parseTemplate()
            var collector = Collector(fileResolver: fileResolver, sourceName: name)
            collector.walk(nodes)
            styles.append(contentsOf: collector.styles)
            scripts.append(contentsOf: collector.scripts)
        }

        let css = styles.joined(separator: "\n")
        var javaScriptParts: [String] = []
        if includeRuntime {
            javaScriptParts.append(PlumeBrowserRuntime.javaScript)
        }
        javaScriptParts.append(contentsOf: scripts)
        let javaScript = javaScriptParts.joined(separator: "\n")

        return PlumeAssetBundle(
            css: css,
            javaScript: javaScript,
            cssFileName: "app.\(PlumeScope.stableHash(css)).css",
            javaScriptFileName: "app.\(PlumeScope.stableHash(javaScript)).js")
    }

    /// Writes the hashed files into `directory`, returning the written URLs.
    @discardableResult
    public func write(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let cssURL = directory.appendingPathComponent(cssFileName)
        let jsURL = directory.appendingPathComponent(javaScriptFileName)
        try css.write(to: cssURL, atomically: true, encoding: .utf8)
        try javaScript.write(to: jsURL, atomically: true, encoding: .utf8)
        return [cssURL, jsURL]
    }

    // MARK: - Collection

    private struct Collector {
        let fileResolver: ((String) -> String?)?
        let sourceName: String
        var styles: [String] = []
        var scripts: [String] = []

        /// Resolve a `file:` resource relative to the template's own directory, so
        /// a component references co-located files by name (`@style(file: "home.css")`
        /// in `Views/Home/Index.plume` → `Views/Home/home.css`). A leading `/` is an
        /// escape hatch for a path relative to the resolver's own root.
        func resolveResourcePath(_ file: String) -> String {
            if file.hasPrefix("/") { return String(file.dropFirst()) }
            let dir = sourceName.split(separator: "/").dropLast().joined(separator: "/")
            return dir.isEmpty ? file : dir + "/" + file
        }

        mutating func walk(_ nodes: [PlumeNode]) {
            for node in nodes {
                switch node {
                case .style(let declaration):
                    collectStyle(declaration)
                case .script(let declaration):
                    collectScript(declaration)
                case .conditional(_, let body, let alternate, _):
                    walk(body)
                    walk(alternate)
                case .loop(_, _, let body, _):
                    walk(body)
                case .slot(_, let fallback, _):
                    walk(fallback)
                case .content(_, let body, _):
                    walk(body)
                case .componentDefinition(let component):
                    walk(component.body)
                case .componentCall(_, _, let body, _):
                    walk(body)
                case .text, .output, .navigation, .image, .state, .assign:
                    continue
                }
            }
        }

        mutating func collectStyle(_ declaration: PlumeStyleDeclaration) {
            guard let css = cssContents(declaration) else { return }
            if declaration.scoped {
                let scope = PlumeScope.styleScope(
                    sourceName: declaration.sourceName, context: declaration.context,
                    css: declaration.css, file: declaration.file)
                styles.append(PlumeCSSScoper.scope(css, attribute: PlumeScope.attribute(for: scope)))
            } else {
                styles.append(css)
            }
        }

        mutating func collectScript(_ declaration: PlumeScriptDeclaration) {
            guard let source = scriptContents(declaration) else { return }
            switch declaration.language {
            case .plume:
                if let compiled = try? PlumeClientScriptCompiler.compile(
                    source, sourceName: declaration.sourceName) {
                    scripts.append(compiled)
                }
            case .javascript:
                scripts.append(source)
            }
        }

        func cssContents(_ declaration: PlumeStyleDeclaration) -> String? {
            if let css = declaration.css { return css }
            if let file = declaration.file { return fileResolver?(resolveResourcePath(file)) }
            return nil
        }

        func scriptContents(_ declaration: PlumeScriptDeclaration) -> String? {
            if let js = declaration.js { return js }
            if let file = declaration.file { return fileResolver?(resolveResourcePath(file)) }
            return nil
        }
    }
}
