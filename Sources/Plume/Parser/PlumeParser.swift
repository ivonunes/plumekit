import Foundation

struct PlumeParser {
    let source: String
    let sourceName: String?
    var index: String.Index
    let lineStarts: [String.Index]

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
            if character == "{", shouldParseOutputExpression() {
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
