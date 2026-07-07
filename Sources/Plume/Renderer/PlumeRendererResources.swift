import Foundation

extension PlumeRenderer {
    mutating func registerStyle(_ declaration: PlumeStyleDeclaration) throws -> String? {
        guard declaration.css != nil || declaration.file != nil else {
            throw PlumeError.template(
                "@style must include a CSS block or a file path.", context: declaration.context)
        }
        let scope = declaration.scoped ? scopeID(for: declaration) : nil
        styles.append(
            PlumeStyleResource(
                css: declaration.css,
                file: declaration.file,
                scoped: declaration.scoped,
                scope: scope,
                sourceName: declaration.sourceName
            ))
        return scope
    }

    mutating func registerScript(_ declaration: PlumeScriptDeclaration) throws -> String? {
        guard declaration.js != nil || declaration.file != nil else {
            throw PlumeError.template(
                "@script must include a JavaScript block or a file path.",
                context: declaration.context)
        }
        let scope = declaration.scoped ? scriptScopeID(for: declaration) : nil
        scripts.append(
            PlumeScriptResource(
                js: declaration.js,
                file: declaration.file,
                language: declaration.language,
                scoped: declaration.scoped,
                scope: scope,
                sourceName: declaration.sourceName,
                context: declaration.context
            ))
        return scope
    }

    mutating func registerNavigation(_ declaration: PlumeNavigationDeclaration) {
        navigation.append(declaration.resource)
    }

    func scopeID(for declaration: PlumeStyleDeclaration) -> String {
        PlumeScope.styleScope(
            sourceName: declaration.sourceName, context: declaration.context,
            css: declaration.css, file: declaration.file)
    }

    func scriptScopeID(for declaration: PlumeScriptDeclaration) -> String {
        PlumeScope.scriptScope(
            sourceName: declaration.sourceName, context: declaration.context,
            js: declaration.js, file: declaration.file, language: declaration.language)
    }

    func addScopeAttributes(_ html: String, scopes: [String]) -> String {
        let scopes = Array(Set(scopes)).sorted()
        guard !scopes.isEmpty else { return html }
        let attributes = scopes.map { "data-plume-scope-\($0)" }
        var output = ""
        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "<" else {
                output.append(html[index])
                index = html.index(after: index)
                continue
            }
            guard let close = html[index...].firstIndex(of: ">") else {
                output.append(contentsOf: html[index...])
                break
            }
            let tagStart = html.index(after: index)
            if tagStart >= html.endIndex {
                output.append(contentsOf: html[index...close])
                index = html.index(after: close)
                continue
            }
            let first = html[tagStart]
            let tag = String(html[index...close])
            if first == "/" || first == "!" || first == "?" {
                output += tag
                index = html.index(after: close)
                continue
            }
            let missing = attributes.filter { !tag.contains($0) }
            guard !missing.isEmpty else {
                output += tag
                index = html.index(after: close)
                continue
            }
            let insertion = " " + missing.joined(separator: " ")
            if tag.hasSuffix("/>") {
                output += String(tag.dropLast(2)) + insertion + " />"
            } else {
                output += String(tag.dropLast()) + insertion + ">"
            }
            index = html.index(after: close)
        }
        return output
    }

    func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    func requiresPlumeRuntime(_ html: String) -> Bool {
        html.contains("data-plume-text")
            || html.contains("data-plume-class")
            || html.contains("data-plume-bind-")
            || html.contains("data-plume-attr-")
            || html.contains("data-plume-style-")
            || html.contains("data-plume-on-")
    }
}
