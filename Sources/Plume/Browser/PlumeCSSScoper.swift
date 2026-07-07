import Foundation

/// Rewrites CSS selectors so a stylesheet only applies to elements carrying a
/// scope attribute.
///
/// Plume's renderer marks elements produced alongside a scoped `@style` block
/// with a `data-plume-scope-*` attribute (see
/// `PlumeStyleResource.scopeAttribute`). Passing that attribute name to
/// `scope(_:attribute:)` rewrites every selector in the stylesheet to require
/// it, so the styles cannot leak outside the scoped markup.
public enum PlumeCSSScoper {
    /// Returns `css` with every selector constrained to elements that carry
    /// `attribute`, e.g. `.card` becomes `.card[data-plume-scope-plume-…]`.
    ///
    /// Conditional group rules (`@media`, `@supports`, `@container`, `@layer`)
    /// are scoped recursively; other at-rules (such as `@keyframes` and
    /// `@font-face`) are left untouched.
    public static func scope(_ css: String, attribute: String) -> String {
        scopeRules(css, attribute: attribute)
    }

    private static func scopeRules(_ css: String, attribute: String) -> String {
        var output = ""
        var index = css.startIndex
        while index < css.endIndex {
            guard let open = nextTopLevelOpenBrace(in: css, from: index) else {
                output.append(contentsOf: css[index...])
                break
            }
            let header = String(css[index..<open])
            guard let close = matchingBrace(in: css, open: open) else {
                output.append(contentsOf: css[index...])
                break
            }
            let bodyStart = css.index(after: open)
            let body = String(css[bodyStart..<close])
            let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedHeader.hasPrefix("@media")
                || trimmedHeader.hasPrefix("@supports")
                || trimmedHeader.hasPrefix("@container")
                || trimmedHeader.hasPrefix("@layer") {
                output += header + "{" + scopeRules(body, attribute: attribute) + "}"
            } else if trimmedHeader.hasPrefix("@") {
                output += header + "{" + body + "}"
            } else {
                output += scopeSelectorList(header, attribute: attribute) + "{" + body + "}"
            }
            index = css.index(after: close)
        }
        return output
    }

    private static func scopeSelectorList(_ selectors: String, attribute: String) -> String {
        splitSelectors(selectors)
            .map { scopeSelector($0, attribute: attribute) }
            .joined(separator: ",")
    }

    private static func scopeSelector(_ selector: String, attribute: String) -> String {
        let leading = selector.prefix { $0.isWhitespace }
        let trailing = selector.reversed().prefix { $0.isWhitespace }
        var core = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return selector }

        let pseudoElementRange = core.range(of: #"::[A-Za-z0-9_-]+(\([^)]*\))?$"#, options: .regularExpression)
        let pseudoElement = pseudoElementRange.map { String(core[$0]) } ?? ""
        if let pseudoElementRange {
            core.removeSubrange(pseudoElementRange)
        }

        // The scope attaches to the KEY compound (the subject — the part after the last
        // top-level combinator), before that compound's first pseudo-class. So
        // `.menu:hover .item` scopes `.item`, not `.menu`.
        var depth = 0
        var quote: Character?
        var insertion = core.endIndex
        var cursor = keyCompoundStart(in: core)
        while cursor < core.endIndex {
            let character = core[cursor]
            if let quoteCharacter = quote {
                if character == "\\" {
                    cursor = core.index(after: cursor)
                    if cursor < core.endIndex { cursor = core.index(after: cursor) }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                cursor = core.index(after: cursor)
                continue
            }
            if character == "\\" {                       // escaped char in an identifier (`.foo\:bar`)
                cursor = core.index(after: cursor)
                if cursor < core.endIndex { cursor = core.index(after: cursor) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0, character == ":" {
                insertion = cursor
                break
            }
            cursor = core.index(after: cursor)
        }

        core.insert(contentsOf: "[\(attribute)]", at: insertion)
        return String(leading) + core + pseudoElement + String(trailing.reversed())
    }

    /// The start of the key compound selector — after the last top-level combinator
    /// (whitespace / `>` / `+` / `~`). Combinator characters inside `(...)`/`[...]` or
    /// strings don't count.
    private static func keyCompoundStart(in core: String) -> String.Index {
        var depth = 0
        var quote: Character?
        var start = core.startIndex
        var inCombinator = false
        var i = core.startIndex
        while i < core.endIndex {
            let c = core[i]
            if let q = quote {
                if c == "\\" { i = core.index(after: i); if i < core.endIndex { i = core.index(after: i) }; continue }
                if c == q { quote = nil }
                i = core.index(after: i); continue
            }
            if c == "\\" {                               // escaped char (e.g. `.foo\ bar`) — not a combinator
                i = core.index(after: i)
                if i < core.endIndex { i = core.index(after: i) }
                inCombinator = false
                continue
            }
            if c == "\"" || c == "'" { quote = c; inCombinator = false }
            else if c == "(" || c == "[" { depth += 1; inCombinator = false }
            else if c == ")" || c == "]" { depth = max(0, depth - 1); inCombinator = false }
            else if depth == 0, c == " " || c == "\t" || c == "\n" || c == ">" || c == "+" || c == "~" {
                inCombinator = true
            } else {
                if inCombinator { start = i }
                inCombinator = false
            }
            i = core.index(after: i)
        }
        return start
    }

    private static func splitSelectors(_ selectors: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        var inComment = false
        var prev: Character = " "
        for character in selectors {
            // Preserve comments verbatim but ignore their contents (a `,` inside a
            // comment must not split the selector list).
            if inComment {
                current.append(character)
                if prev == "*", character == "/" { inComment = false }
                prev = character
                continue
            }
            if prev == "/", character == "*", quote == nil {
                current.append(character); inComment = true; prev = character; continue
            }
            if let quoteCharacter = quote {
                current.append(character)
                if escaped { escaped = false }             // this char was escaped
                else if character == "\\" { escaped = true }
                else if character == quoteCharacter { quote = nil }
                prev = character
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                prev = character
                continue
            }
            if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth = max(0, depth - 1)
            }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            prev = character
        }
        parts.append(current)
        return parts
    }

    private static func nextTopLevelOpenBrace(in css: String, from start: String.Index) -> String.Index? {
        var index = start
        var quote: Character?
        var inComment = false
        while index < css.endIndex {
            let character = css[index]
            if inComment {
                if character == "*", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "/" {
                    index = css.index(index, offsetBy: 2)
                    inComment = false
                    continue
                }
                index = css.index(after: index)
                continue
            }
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = css.index(after: index)
                    if index < css.endIndex { index = css.index(after: index) }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = css.index(after: index)
                continue
            }
            if character == "/", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "*" {
                index = css.index(index, offsetBy: 2)
                inComment = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = css.index(after: index)
                continue
            }
            if character == "{" { return index }
            index = css.index(after: index)
        }
        return nil
    }

    private static func matchingBrace(in css: String, open: String.Index) -> String.Index? {
        var index = css.index(after: open)
        var depth = 1
        var quote: Character?
        var inComment = false
        while index < css.endIndex {
            let character = css[index]
            if inComment {
                if character == "*", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "/" {
                    index = css.index(index, offsetBy: 2)
                    inComment = false
                    continue
                }
                index = css.index(after: index)
                continue
            }
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = css.index(after: index)
                    if index < css.endIndex { index = css.index(after: index) }
                    continue
                }
                if character == quoteCharacter { quote = nil }
                index = css.index(after: index)
                continue
            }
            if character == "/", css.index(after: index) < css.endIndex, css[css.index(after: index)] == "*" {
                index = css.index(index, offsetBy: 2)
                inComment = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = css.index(after: index)
                continue
            }
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = css.index(after: index)
        }
        return nil
    }
}
