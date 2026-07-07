//
//  PlumeSwiftDesugar.swift
//  Plume — compiling back-end
//
//  Source-to-source desugaring of the attribute helpers for the COMPILING
//  back-end. The interpreting renderer implements `class:`, `class+=`, `attr?=`
//  and `attr:value=` as a render-time pass over the produced HTML; a compiled
//  template is a token stream, so the helpers are rewritten into inline `@if`
//  blocks before parsing instead:
//
//    <a class="x" class:active="{cond}">   → <a class="x@if cond { active}">
//    <input value?="{v}">                  → <input@if v { value="{v}"}>
//    <a aria-current:page="{cond}">        → <a@if cond { aria-current="page"}>
//    <li class+="{kind}">                  → <li class="@if kind { kind-value}">
//
//  `on:` and `style:` helpers are @state/client-runtime features and pass
//  through untouched (the binding core wires them in the browser). This file
//  runs at build time in the host CLI, so Foundation is fine here.
//

import Foundation

public enum PlumeCompiledDesugar {
    static let tagPattern = try! NSRegularExpression(
        pattern: #"<[^!/](?:[^<>"']|"[^"]*"|'[^']*')*>"#, options: [.dotMatchesLineSeparators])
    static let classAppendPattern = try! NSRegularExpression(
        pattern: #"\sclass\+=(?:"([^"]*)"|'([^']*)')"#)
    static let classHelperPattern = try! NSRegularExpression(
        pattern: #"\sclass:([A-Za-z0-9_-]+)=(?:"([^"]*)"|'([^']*)')"#)
    static let conditionalAttributePattern = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_][-A-Za-z0-9_]*):([A-Za-z0-9_.:-]+)=(?:"([^"]*)"|'([^']*)')"#)
    static let optionalAttributePattern = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_][-A-Za-z0-9_]*)\?=(?:"([^"]*)"|'([^']*)')"#)
    static let classAttributePattern = try! NSRegularExpression(
        pattern: #"\sclass="([^"]*)""#)

    /// Rewrite attribute helpers in `source` into inline `@if` blocks.
    public static func desugar(_ source: String) -> String {
        let ns = source as NSString
        var output = source
        for match in tagPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tag = ns.substring(with: match.range)
            // Skip tags with no helper syntax, and never touch @script/@style bodies
            // (they aren't tags, so the tag regex won't match them anyway).
            guard tag.contains("?=") || tag.contains("class+=") || containsHelperColon(tag) else { continue }
            let processed = processTag(tag)
            if processed != tag, let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: processed)
            }
        }
        return output
    }

    /// Cheap pre-check: a `name:sub="` attribute other than on:/style:/data-plume.
    // `on:`/`style:` are their own helpers; `xmlns`/`xml`/`xlink`/`epub` are real
    // XML namespaces, not helpers — a `name:value=` rewrite would corrupt them. This
    // mirrors the interpreting renderer's `xmlNamespaceAttributePrefixes` so both
    // back-ends treat these identically.
    private static let reservedAttributePrefixes: Set<String> =
        ["on", "style", "xmlns", "xml", "xlink", "epub"]

    private static func containsHelperColon(_ tag: String) -> Bool {
        let ns = tag as NSString
        let matches = conditionalAttributePattern.matches(in: tag, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let name = ns.substring(with: match.range(at: 1))
            if reservedAttributePrefixes.contains(name) { continue }
            return true
        }
        return false
    }


    /// First present capture group among `indexes` (double- vs single-quoted value).
    private static func capture(_ ns: NSString, _ match: NSTextCheckingResult, _ indexes: [Int]) -> String {
        for index in indexes where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return ""
    }

    private static func processTag(_ original: String) -> String {
        var tag = original
        var classInsertions: [String] = []   // rendered inside the class attribute value

        // class+="{expr}" / class+="literal" — append to the class list.
        while true {
            let ns = tag as NSString
            guard let match = classAppendPattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { break }
            let raw = capture(ns, match, [1, 2])
            if let expression = binding(raw) {
                classInsertions.append("@if \(expression) { {\(expression)}}")
            } else if !raw.isEmpty {
                classInsertions.append(" \(raw)")
            }
            guard let range = Range(match.range, in: tag) else { break }
            tag.removeSubrange(range)
        }

        // class:name="{cond}" — append `name` when the condition is truthy.
        while true {
            let ns = tag as NSString
            guard let match = classHelperPattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { break }
            let name = ns.substring(with: match.range(at: 1))
            let raw = capture(ns, match, [2, 3])
            if let expression = binding(raw) {
                classInsertions.append("@if \(expression) { \(name)}")
            } else if truthyLiteral(raw) {
                classInsertions.append(" \(name)")
            }
            guard let range = Range(match.range, in: tag) else { break }
            tag.removeSubrange(range)
        }

        // attr:value="{cond}" — write attr="value" when truthy (skip on:/style:).
        while true {
            let ns = tag as NSString
            var found: NSTextCheckingResult?
            for match in conditionalAttributePattern.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if reservedAttributePrefixes.contains(name) { continue }
                found = match
                break
            }
            guard let match = found else { break }
            let name = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            let raw = capture(ns, match, [3, 4])
            let replacement: String
            if let expression = binding(raw) {
                replacement = "@if \(expression) { \(name)=\"\(value)\"}"
            } else if truthyLiteral(raw) {
                replacement = " \(name)=\"\(value)\""
            } else {
                replacement = ""
            }
            guard let range = Range(match.range, in: tag) else { break }
            tag.replaceSubrange(range, with: replacement)
        }

        // attr?="{expr}" — write attr="<value>" only when the value is truthy.
        while true {
            let ns = tag as NSString
            guard let match = optionalAttributePattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { break }
            let name = ns.substring(with: match.range(at: 1))
            let raw = capture(ns, match, [2, 3])
            let replacement: String
            if let expression = binding(raw) {
                replacement = "@if \(expression) { \(name)=\"{\(expression)}\"}"
            } else if truthyLiteral(raw) {
                replacement = " \(name)=\"\(raw)\""
            } else {
                replacement = ""
            }
            guard let range = Range(match.range, in: tag) else { break }
            tag.replaceSubrange(range, with: replacement)
        }

        // Merge collected class additions into the static class attribute (or
        // synthesize one right before the tag close).
        if !classInsertions.isEmpty {
            let insertion = classInsertions.joined()
            let ns = tag as NSString
            if let match = classAttributePattern.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) {
                let valueRange = match.range(at: 1)
                let end = valueRange.location + valueRange.length
                if let insertAt = Range(NSRange(location: end, length: 0), in: tag) {
                    tag.replaceSubrange(insertAt, with: insertion)
                }
            } else {
                // No static class attribute: add one carrying only the dynamic parts.
                let closeIndex = tag.hasSuffix("/>") ? tag.index(tag.endIndex, offsetBy: -2) : tag.index(before: tag.endIndex)
                tag.replaceSubrange(closeIndex..<closeIndex, with: " class=\"\(insertion)\"")
            }
        }

        return tag
    }

    /// "{expr}" → expr; anything else is a literal.
    private static func binding(_ raw: String) -> String? {
        guard raw.hasPrefix("{"), raw.hasSuffix("}"), raw.count >= 2 else { return nil }
        let inner = String(raw.dropFirst().dropLast())
        guard !inner.contains("{") else { return nil }   // nested interpolation unsupported
        return inner.trimmingCharacters(in: .whitespaces)
    }

    private static func truthyLiteral(_ raw: String) -> Bool {
        !(raw.isEmpty || raw == "false" || raw == "nil" || raw == "null")
    }
}
