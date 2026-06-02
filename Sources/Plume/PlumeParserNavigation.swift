import Foundation

extension PlumeParser {
    var navigationScrollModes: Set<String> {
        ["top", "preserve", "none"]
    }

    var navigationHookNames: Set<String> {
        ["start", "beforeSwap", "afterSwap", "complete", "error"]
    }

    func parseNavigationHooks(_ raw: String, context: PlumeSourceContext?) throws
        -> [PlumeNavigationHook]
    {
        var hooks: [PlumeNavigationHook] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            cursor = skipWhitespace(in: raw, from: cursor)
            guard cursor < raw.endIndex else { break }
            guard raw[cursor...].hasPrefix("on:") else {
                throw error("@navigation blocks only support on:<hook> { ... }.", at: context)
            }
            cursor = raw.index(cursor, offsetBy: "on:".count)
            let nameStart = cursor
            while cursor < raw.endIndex,
                raw[cursor].isLetter || raw[cursor].isNumber || raw[cursor] == "_"
                    || raw[cursor] == "-"
            {
                cursor = raw.index(after: cursor)
            }
            let name = String(raw[nameStart..<cursor])
            guard navigationHookNames.contains(name) else {
                throw error("Unknown @navigation hook \(name).", at: context)
            }
            cursor = skipWhitespace(in: raw, from: cursor)
            guard cursor < raw.endIndex, raw[cursor] == "{" else {
                throw error("Missing opening { for @navigation hook \(name).", at: context)
            }
            let block = try navigationHookBlock(in: raw, from: cursor, name: name, context: context)
            let actions = try navigationActions(in: block.body, hook: name, context: context)
            hooks.append(PlumeNavigationHook(name: name, actions: actions))
            cursor = block.end
        }
        return hooks
    }

    func navigationActions(in body: String, hook: String, context: PlumeSourceContext?) throws
        -> [String]
    {
        let actions = body.components(separatedBy: .newlines).flatMap { line in
            splitExpression(line, separator: ";")
        }
        .map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingSuffix(";")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        for action in actions {
            guard
                action.range(
                    of: #"^page\.[A-Za-z_][A-Za-z0-9_]*\(.*\)$"#, options: .regularExpression)
                    != nil
            else {
                throw error("@navigation hook \(hook) actions must use page actions.", at: context)
            }
        }
        return actions
    }

    func navigationHookBlock(
        in raw: String, from open: String.Index, name: String, context: PlumeSourceContext?
    ) throws -> (body: String, end: String.Index) {
        var cursor = raw.index(after: open)
        let start = cursor
        var depth = 1
        var quote: Character?
        while cursor < raw.endIndex {
            let character = raw[cursor]
            if let quoteCharacter = quote {
                if character == "\\" {
                    cursor = raw.index(after: cursor)
                    if cursor < raw.endIndex { cursor = raw.index(after: cursor) }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                cursor = raw.index(after: cursor)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                cursor = raw.index(after: cursor)
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let body = String(raw[start..<cursor])
                    return (body, raw.index(after: cursor))
                }
            }
            cursor = raw.index(after: cursor)
        }
        throw error("Missing closing } for @navigation hook \(name).", at: context)
    }

    func skipWhitespace(in source: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
        return cursor
    }
}
