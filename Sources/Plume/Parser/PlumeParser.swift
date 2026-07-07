import Foundation

struct PlumeParser {
    let source: String
    let sourceName: String?
    var index: String.Index
    let lineStarts: [String.Index]
    private var nestingDepth = 0
    /// Cap structural nesting so a pathologically deep template can't overflow the build
    /// tool's stack — a clean error beats a crash. Far deeper than any real template.
    private static let maxNestingDepth = 256

    init(_ source: String, sourceName: String? = nil) {
        self.source = source
        self.sourceName = sourceName
        self.index = source.startIndex
        var lineStarts = [source.startIndex]
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor] == "\n" {
                lineStarts.append(source.index(after: cursor))
            }
            cursor = source.index(after: cursor)
        }
        self.lineStarts = lineStarts
    }

    mutating func parseTemplate() throws -> [PlumeNode] {
        let parsed = try parseNodes(untilClosingBrace: false)
        return parsed.nodes
    }

    mutating func parseNodes(untilClosingBrace: Bool) throws -> (nodes: [PlumeNode], closed: Bool) {
        nestingDepth += 1
        defer { nestingDepth -= 1 }
        guard nestingDepth <= Self.maxNestingDepth else {
            throw error("Template nested too deeply (over \(Self.maxNestingDepth) levels).")
        }
        var nodes: [PlumeNode] = []
        var text = ""
        var textBraceDepth = 0

        func flushText() {
            guard !text.isEmpty else { return }
            nodes.append(.text(text))
            text = ""
        }

        while index < source.endIndex {
            if shouldParseDirective("@style", allowingBlockBody: true) {
                flushText()
                nodes.append(try parseStyle())
                continue
            }
            if shouldParseDirective("@script", allowingBlockBody: true) {
                flushText()
                nodes.append(try parseScript())
                continue
            }
            if shouldParseDirective("@navigation", allowingBlockBody: true) {
                flushText()
                nodes.append(try parseNavigation())
                continue
            }
            if shouldParseDirective("@image", allowingBlockBody: false) {
                flushText()
                nodes.append(try parseImage())
                continue
            }
            if shouldParseSlotDirective() {
                flushText()
                nodes.append(try parseSlot())
                continue
            }
            if shouldParseDirective("@content", allowingBlockBody: false) {
                flushText()
                nodes.append(try parseContent())
                continue
            }
            if shouldParseCSRFDirective() {
                flushText()
                let context = sourceContext(at: index)
                advance(by: "@csrf".count)
                // Desugar to a hidden input carrying the request's CSRF token, so the
                // form passes `csrfProtection()`. The token is ambient (the framework
                // binds it per request), so nothing needs to be threaded through the
                // view or its handler.
                nodes.append(.text("<input type=\"hidden\" name=\"_csrf\" value=\""))
                nodes.append(.output("RenderContext.currentCSRFToken", context))
                nodes.append(.text("\">"))
                continue
            }
            if starts(with: "@state ") {
                flushText()
                nodes.append(try parseState())
                continue
            }
            if starts(with: "@let ") {
                flushText()
                nodes.append(try parseLet())
                continue
            }
            if starts(with: "@component ") {
                flushText()
                nodes.append(try parseComponentDefinition())
                continue
            }
            if starts(with: "@if ") {
                flushText()
                nodes.append(try parseConditional())
                continue
            }
            if starts(with: "@for ") {
                flushText()
                nodes.append(try parseLoop())
                continue
            }
            if starts(with: "@comment") {
                flushText()
                try parseComment()
                continue
            }
            if shouldParseComponentCall() {
                flushText()
                nodes.append(try parseComponentCall())
                continue
            }
            if starts(with: "{{") || starts(with: "{%") {
                throw error("Legacy Liquid delimiters are not valid Plume syntax.")
            }

            let character = source[index]
            if character == "{", shouldParseOutputExpression(text) {
                // Escaping neutralises `<`/`>`/`"`/`'` but not spaces, so an interpolation
                // in an UNQUOTED attribute value (`<a href={url}>`) could inject an
                // attribute. Require quotes, where escaping fully protects the value.
                if endsInUnquotedAttribute(text) {
                    throw error("Quote an interpolated attribute value: write attr=\"{...}\", not attr={...}.")
                }
                flushText()
                let context = sourceContext(at: index)
                advance()
                nodes.append(.output(try readBracedExpression(), context))
                continue
            }
            if character == "{" {
                text.append(character)
                textBraceDepth += 1
                advance()
                continue
            }
            if character == "}" {
                if textBraceDepth > 0 {
                    text.append(character)
                    textBraceDepth -= 1
                    advance()
                    continue
                }
                if untilClosingBrace {
                    advance()
                    flushText()
                    return (nodes, true)
                }
                text.append(character)
                advance()
                continue
            }

            text.append(character)
            advance()
        }

        flushText()
        if untilClosingBrace {
            throw error("Missing closing } in Plume block.")
        }
        return (nodes, false)
    }
}
