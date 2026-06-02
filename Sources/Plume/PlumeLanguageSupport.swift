import Foundation

public enum PlumeDiagnosticSeverity: Int, Sendable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4
}

public struct PlumeDiagnostic: Equatable, Sendable {
    public var message: String
    public var severity: PlumeDiagnosticSeverity
    public var sourceName: String?
    public var line: Int
    public var column: Int
    public var sourceLine: String

    public init(
        message: String,
        severity: PlumeDiagnosticSeverity = .error,
        sourceName: String? = nil,
        line: Int = 1,
        column: Int = 1,
        sourceLine: String = ""
    ) {
        self.message = message
        self.severity = severity
        self.sourceName = sourceName
        self.line = max(1, line)
        self.column = max(1, column)
        self.sourceLine = sourceLine
    }
}

public struct PlumeCompletion: Equatable, Sendable {
    public var label: String
    public var detail: String
    public var insertText: String
    public var kind: Int
    public var isSnippet: Bool

    public init(label: String, detail: String, insertText: String? = nil, kind: Int, isSnippet: Bool = false) {
        self.label = label
        self.detail = detail
        self.insertText = insertText ?? label
        self.kind = kind
        self.isSnippet = isSnippet
    }
}

public struct PlumeDocumentSymbol: Equatable, Sendable {
    public var name: String
    public var detail: String
    public var kind: Int
    public var line: Int
    public var column: Int

    public init(name: String, detail: String = "", kind: Int, line: Int, column: Int) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.line = max(1, line)
        self.column = max(1, column)
    }
}

public enum PlumeLanguageSupport {
    public static func diagnostics(
        for source: String,
        sourceName: String? = nil,
        componentSources: [String: String] = [:]
    ) -> [PlumeDiagnostic] {
        do {
            let environment = try PlumeTemplateEnvironment(componentSources: componentSources)
            let template = try PlumeTemplate(source, sourceName: sourceName, environment: environment)
            let result = try template.check()
            return scriptDiagnostics(in: result.scripts)
        } catch {
            return [diagnostic(from: error, fallbackSourceName: sourceName)]
        }
    }

    public static func format(_ source: String) -> String {
        PlumeFormatter.format(source)
    }

    public static func completions() -> [PlumeCompletion] {
        directiveCompletions + filterCompletions + contextCompletions + attributeCompletions
    }

    public static func symbols(in source: String) -> [PlumeDocumentSymbol] {
        let lines = source.components(separatedBy: .newlines)
        return lines.enumerated().flatMap { index, line -> [PlumeDocumentSymbol] in
            let lineNumber = index + 1
            return [
                symbol(in: line, lineNumber: lineNumber, pattern: #"@component\s+([A-Z][A-Za-z0-9_]*)"#, detail: "component", kind: 5),
                symbol(in: line, lineNumber: lineNumber, pattern: #"@state\s+([A-Za-z_][A-Za-z0-9_]*)"#, detail: "state", kind: 13),
                symbol(in: line, lineNumber: lineNumber, pattern: #"@let\s+([A-Za-z_][A-Za-z0-9_]*)"#, detail: "local", kind: 13),
                symbol(in: line, lineNumber: lineNumber, pattern: #"@navigation\b"#, name: "navigation", detail: "navigation", kind: 12),
                symbol(in: line, lineNumber: lineNumber, pattern: #"@style\b"#, name: "style", detail: "style", kind: 12),
                symbol(in: line, lineNumber: lineNumber, pattern: #"@script\b"#, name: "script", detail: "script", kind: 12)
            ].compactMap { $0 }
        }
    }

    private static func scriptDiagnostics(in scripts: [PlumeScriptResource]) -> [PlumeDiagnostic] {
        scripts.compactMap { script in
            guard script.language == .plume, let source = script.js else { return nil }
            do {
                _ = try PlumeClientScriptCompiler.compile(source, sourceName: script.sourceName)
                return nil
            } catch {
                return diagnostic(from: error, fallbackSourceName: script.sourceName, embeddedIn: script.context)
            }
        }
    }

    private static func diagnostic(from error: Error, fallbackSourceName: String?, embeddedIn parentContext: PlumeSourceContext? = nil) -> PlumeDiagnostic {
        if let plumeError = error as? PlumeError {
            let context = plumeError.context
            let embeddedLineOffset = parentContext.map { $0.line } ?? 0
            return PlumeDiagnostic(
                message: plumeError.message,
                sourceName: context?.sourceName ?? fallbackSourceName,
                line: (context?.line ?? 1) + embeddedLineOffset,
                column: context?.column ?? 1,
                sourceLine: context?.sourceLine ?? ""
            )
        }
        return PlumeDiagnostic(message: String(describing: error), sourceName: fallbackSourceName)
    }

    private static func symbol(
        in line: String,
        lineNumber: Int,
        pattern: String,
        name explicitName: String? = nil,
        detail: String,
        kind: Int
    ) -> PlumeDocumentSymbol? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        let name: String
        let nameRange: NSRange
        if let explicitName {
            name = explicitName
            nameRange = match.range(at: 0)
        } else if match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: line) {
            name = String(line[range])
            nameRange = match.range(at: 1)
        } else {
            return nil
        }
        return PlumeDocumentSymbol(name: name, detail: detail, kind: kind, line: lineNumber, column: nameRange.location + 1)
    }

    private static let directiveCompletions: [PlumeCompletion] = [
        PlumeCompletion(label: "@component", detail: "Define a reusable component", insertText: "@component ${1:Name}(${2:parameter}) {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@if", detail: "Render content conditionally", insertText: "@if ${1:condition} {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@for", detail: "Loop over a collection", insertText: "@for ${1:item} in ${2:items} {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@style", detail: "Attach CSS to the rendered page", insertText: "@style {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@style(file:)", detail: "Attach a CSS file", insertText: "@style(file: \"${1:styles/site.css}\")", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@script", detail: "Attach a Plume client script", insertText: "@script {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@script(file:)", detail: "Attach a script file", insertText: "@script(file: \"${1:scripts/site.plume}\")", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@navigation", detail: "Enable enhanced navigation", insertText: "@navigation(root: \"${1:body}\", viewTransitions: true, scroll: \"top\") {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@image", detail: "Render a responsive optimized image", insertText: "@image(\"${1:path.jpg}\", alt: \"${2:Description}\")", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@state", detail: "Define client-side state", insertText: "@state ${1:name} = ${2:false}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@let", detail: "Define a template local", insertText: "@let ${1:name} = ${2:value}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@slot", detail: "Render component slot content", insertText: "@slot", kind: 14),
        PlumeCompletion(label: "@content", detail: "Provide named slot content", insertText: "@content(${1:name}) {\n  ${0}\n}", kind: 15, isSnippet: true),
        PlumeCompletion(label: "@comment", detail: "Comment out a Plume block", insertText: "@comment {\n  ${0}\n}", kind: 15, isSnippet: true)
    ]

    private static let filterCompletions: [PlumeCompletion] = [
        PlumeCompletion(label: "raw", detail: "Render trusted HTML without escaping", kind: 3),
        PlumeCompletion(label: "default", detail: "Fallback when a value is empty", insertText: "default(${1:value})", kind: 3, isSnippet: true),
        PlumeCompletion(label: "date", detail: "Format a date", insertText: "date(\"${1:d MMMM yyyy}\")", kind: 3, isSnippet: true),
        PlumeCompletion(label: "json", detail: "Encode as JSON", kind: 3),
        PlumeCompletion(label: "urlEncode", detail: "Percent-encode a string", kind: 3),
        PlumeCompletion(label: "newlineToBR", detail: "Convert newlines to <br>", kind: 3),
        PlumeCompletion(label: "truncateWords", detail: "Limit text by word count", insertText: "truncateWords(${1:30})", kind: 3, isSnippet: true),
        PlumeCompletion(label: "sort", detail: "Sort a collection", insertText: "sort(\"${1:field}\")", kind: 3, isSnippet: true),
        PlumeCompletion(label: "where", detail: "Filter a collection by field", insertText: "where(\"${1:field}\", ${2:value})", kind: 3, isSnippet: true),
        PlumeCompletion(label: "map", detail: "Map a collection field", insertText: "map(\"${1:field}\")", kind: 3, isSnippet: true),
        PlumeCompletion(label: "join", detail: "Join collection values", insertText: "join(\"${1:,}\")", kind: 3, isSnippet: true)
    ]

    private static let contextCompletions: [PlumeCompletion] = [
        PlumeCompletion(label: "site", detail: "Site metadata and navigation", kind: 6),
        PlumeCompletion(label: "posts", detail: "Published posts", kind: 6),
        PlumeCompletion(label: "post", detail: "Current post", kind: 6),
        PlumeCompletion(label: "page", detail: "Current page", kind: 6),
        PlumeCompletion(label: "category", detail: "Current category", kind: 6),
        PlumeCompletion(label: "feed", detail: "Current feed context", kind: 6),
        PlumeCompletion(label: "collections", detail: "Content collections", kind: 6),
        PlumeCompletion(label: "data", detail: "Configured remote data sources", kind: 6),
        PlumeCompletion(label: "asset", detail: "Resolve a theme asset path", insertText: "asset(\"${1:path}\")", kind: 3, isSnippet: true)
    ]

    private static let attributeCompletions: [PlumeCompletion] = [
        PlumeCompletion(label: "class:", detail: "Conditionally add a class", insertText: "class:${1:name}=\"{${2:condition}}\"", kind: 10, isSnippet: true),
        PlumeCompletion(label: "class+", detail: "Append dynamic class names", insertText: "class+=\"{${1:expression}}\"", kind: 10, isSnippet: true),
        PlumeCompletion(label: "hidden?", detail: "Conditionally include hidden", insertText: "hidden?=\"{${1:condition}}\"", kind: 10, isSnippet: true),
        PlumeCompletion(label: "on:click", detail: "Run a Plume action on click", insertText: "on:click=\"{${1:state.toggle()}}\"", kind: 10, isSnippet: true),
        PlumeCompletion(label: "style:", detail: "Bind a style property", insertText: "style:${1:property}=\"{${2:value}}\"", kind: 10, isSnippet: true)
    ]
}
