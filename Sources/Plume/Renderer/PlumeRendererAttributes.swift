import Foundation

extension PlumeRenderer {
    static let bindingMarkerPrefix = "__PLUME_BINDING_"

    static let tagRegex = try! NSRegularExpression(
        pattern: #"<[^!/](?:[^<>"']|"[^"]*"|'[^']*')*>"#)
    static let eventRegex = try! NSRegularExpression(
        pattern: #"\son:([A-Za-z][A-Za-z0-9_-]*)=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let styleHelperRegex = try! NSRegularExpression(
        pattern: #"\sstyle:([-A-Za-z_][-A-Za-z0-9_]*|--[-A-Za-z0-9_-]+)=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let classAppendRegex = try! NSRegularExpression(
        pattern: #"\sclass\+=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let classHelperRegex = try! NSRegularExpression(
        pattern: #"\sclass:([A-Za-z0-9_-]+)=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let conditionalAttributeRegex = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*):([A-Za-z0-9_.:-]+)=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let optionalAttributeRegex = try! NSRegularExpression(
        pattern: #"\s([A-Za-z_:][-A-Za-z0-9_:.]*)\?=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    static let classAttributeRegex = try! NSRegularExpression(
        pattern: #"\sclass="([^"]*)""#)

    mutating func renderAttributeHelpers(_ html: String) throws -> String {
        let regex = Self.tagRegex
        let ns = html as NSString
        var output = html
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .reversed()
        {
            let tag = ns.substring(with: match.range)
            let processed = processTag(tag)
            if processed != tag, let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: processed)
            }
        }
        return replaceTextBindings(output)
    }

    mutating func processTag(_ tag: String) -> String {
        guard
            tag.contains(":") || tag.contains("?=") || tag.contains("+=")
                || tag.contains(Self.bindingMarkerPrefix)
        else {
            return tag
        }
        var output = tag
        var activeClasses: [String] = []
        do {
            let regex = Self.eventRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let event = ns.substring(with: match.range(at: 1))
                let value = capture(in: ns, match: match, indexes: [2, 3, 4])
                let action = binding(for: value)?.expression ?? value
                let replacement = #" data-plume-on-\#(event)="\#(escapeAttribute(action))""#
                if let range = Range(match.range, in: output) {
                    output.replaceSubrange(range, with: replacement)
                }
            }
        }

        do {
            let regex = Self.styleHelperRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let property = ns.substring(with: match.range(at: 1))
                let value = capture(in: ns, match: match, indexes: [2, 3, 4])
                if let range = Range(match.range, in: output) {
                    output.removeSubrange(range)
                }
                if let binding = binding(for: value) {
                    output = setStyleProperty(property, value: binding.rendered, in: output)
                    output = setAttribute(
                        "data-plume-style-\(property)", value: binding.expression, in: output)
                } else if let template = styleBindingTemplate(for: value) {
                    output = setStyleProperty(property, value: template.rendered, in: output)
                    output = setAttribute(
                        "data-plume-style-template-\(property)", value: template.expression,
                        in: output)
                } else {
                    output = setStyleProperty(property, value: value, in: output)
                }
            }
        }

        do {
            let regex = Self.classAppendRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let value = capture(in: ns, match: match, indexes: [1, 2, 3])
                if let binding = binding(for: value) {
                    if truthyString(binding.rendered) {
                        activeClasses.insert(binding.rendered, at: 0)
                    }
                    output = setAttribute("data-plume-class", value: binding.expression, in: output)
                } else if truthyString(value) {
                    activeClasses.insert(value, at: 0)
                }
                if let range = Range(match.range, in: output) {
                    output.removeSubrange(range)
                }
            }
        }

        do {
            let regex = Self.classHelperRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let name = ns.substring(with: match.range(at: 1))
                let value = capture(in: ns, match: match, indexes: [2, 3, 4])
                if let binding = binding(for: value) {
                    if truthyString(binding.rendered) {
                        activeClasses.insert(name, at: 0)
                    }
                    output = setAttribute(
                        "data-plume-class-\(name)", value: binding.expression, in: output)
                } else if truthyString(value) {
                    activeClasses.insert(name, at: 0)
                }
                if let range = Range(match.range, in: output) {
                    output.removeSubrange(range)
                }
            }
        }

        do {
            let regex = Self.conditionalAttributeRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let name = ns.substring(with: match.range(at: 1))
                guard name != "class", !xmlNamespaceAttributePrefixes.contains(name) else {
                    continue
                }
                let activeValue = ns.substring(with: match.range(at: 2))
                let condition = capture(in: ns, match: match, indexes: [3, 4, 5])
                if let range = Range(match.range, in: output) {
                    output.removeSubrange(range)
                }
                if let binding = binding(for: condition) {
                    if truthyString(binding.rendered) {
                        output = setAttribute(name, value: activeValue, in: output)
                    }
                    output = setAttribute(
                        "data-plume-attr-\(name)", value: binding.expression, in: output)
                    output = setAttribute(
                        "data-plume-attr-\(name)-value", value: activeValue, in: output)
                } else if truthyString(condition) {
                    output = setAttribute(name, value: activeValue, in: output)
                }
            }
        }

        do {
            let regex = Self.optionalAttributeRegex
            let ns = output as NSString
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
                .reversed()
            {
                let name = ns.substring(with: match.range(at: 1))
                let value = capture(in: ns, match: match, indexes: [2, 3, 4])
                let replacement: String
                if let binding = binding(for: value) {
                    if truthyString(binding.rendered) {
                        replacement =
                            booleanAttributes.contains(name) && binding.rendered == "true"
                            ? #" \#(name) data-plume-attr-\#(name)="\#(escapeAttribute(binding.expression))""#
                            : #" \#(name)="\#(escapeAttribute(binding.rendered))" data-plume-attr-\#(name)="\#(escapeAttribute(binding.expression))""#
                    } else {
                        replacement =
                            #" data-plume-attr-\#(name)="\#(escapeAttribute(binding.expression))""#
                    }
                } else if truthyString(value) {
                    replacement =
                        booleanAttributes.contains(name) && value == "true"
                        ? " \(name)" : #" \#(name)="\#(escapeAttribute(value))""#
                } else {
                    replacement = ""
                }
                if let range = Range(match.range, in: output) {
                    output.replaceSubrange(range, with: replacement)
                }
            }
        }

        output = replaceAttributeBindings(output)

        guard !activeClasses.isEmpty else { return output }
        let joined = activeClasses.joined(separator: " ")
        if let match = Self.classAttributeRegex.firstMatch(
            in: output, range: NSRange(location: 0, length: (output as NSString).length)),
            let classRange = Range(match.range(at: 1), in: output)
        {
            let current = String(output[classRange])
            output.replaceSubrange(
                classRange, with: [current, joined].filter { !$0.isEmpty }.joined(separator: " "))
            return output
        }
        let insertion =
            output.hasSuffix("/>")
            ? output.index(output.endIndex, offsetBy: -2) : output.index(before: output.endIndex)
        output.insert(contentsOf: #" class="\#(joined)""#, at: insertion)
        return output
    }

    var booleanAttributes: Set<String> {
        [
            "allowfullscreen", "async", "autofocus", "autoplay", "checked", "controls", "defer",
            "disabled", "hidden", "loop", "multiple", "muted", "open", "readonly", "required",
            "selected",
        ]
    }

    var xmlNamespaceAttributePrefixes: Set<String> {
        ["xmlns", "xml", "xlink", "epub"]
    }

    func setAttribute(_ name: String, value: String, in tag: String) -> String {
        var output = tag
        if let regex = PlumeRegexCache.shared.regex(
            #"\s\#(NSRegularExpression.escapedPattern(for: name))=(?:"[^"]*"|'[^']*'|[^\s>]+)"#),
            let match = regex.firstMatch(
                in: output, range: NSRange(location: 0, length: (output as NSString).length)),
            let range = Range(match.range, in: output)
        {
            output.replaceSubrange(range, with: #" \#(name)="\#(escapeAttribute(value))""#)
            return output
        }
        let insertion =
            output.hasSuffix("/>")
            ? output.index(output.endIndex, offsetBy: -2) : output.index(before: output.endIndex)
        output.insert(contentsOf: #" \#(name)="\#(escapeAttribute(value))""#, at: insertion)
        return output
    }

    func removeAttribute(_ name: String, in tag: String) -> String {
        var output = tag
        guard
            let regex = PlumeRegexCache.shared.regex(
                #"\s\#(NSRegularExpression.escapedPattern(for: name))=(?:"[^"]*"|'[^']*'|[^\s>]+)"#
            ),
            let match = regex.firstMatch(
                in: output, range: NSRange(location: 0, length: (output as NSString).length)),
            let range = Range(match.range, in: output)
        else {
            return output
        }
        output.removeSubrange(range)
        return output
    }

    func setStyleProperty(_ property: String, value: String, in tag: String) -> String {
        let style = existingAttribute("style", in: tag) ?? ""
        var declarations = styleDeclarations(from: style).filter {
            !styleProperty($0.property, matches: property)
        }
        if truthyString(value) {
            declarations.append((property: property, value: value))
        }
        guard !declarations.isEmpty else {
            return removeAttribute("style", in: tag)
        }
        let rendered =
            declarations
            .map { "\($0.property): \($0.value)" }
            .joined(separator: "; ") + ";"
        return setAttribute("style", value: rendered, in: tag)
    }

    func existingAttribute(_ name: String, in tag: String) -> String? {
        guard
            let regex = PlumeRegexCache.shared.regex(
                #"\s\#(NSRegularExpression.escapedPattern(for: name))=(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
            ),
            let match = regex.firstMatch(
                in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else {
            return nil
        }
        return capture(in: tag as NSString, match: match, indexes: [1, 2, 3])
    }

    func styleDeclarations(from style: String) -> [(property: String, value: String)] {
        style.split(separator: ";").compactMap { rawDeclaration in
            let declaration = rawDeclaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = declaration.firstIndex(of: ":") else { return nil }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !property.isEmpty, !value.isEmpty else { return nil }
            return (property: property, value: value)
        }
    }

    func styleProperty(_ left: String, matches right: String) -> Bool {
        if left.hasPrefix("--") || right.hasPrefix("--") {
            return left == right
        }
        return left.lowercased() == right.lowercased()
    }

    func binding(for marker: String) -> PlumeBinding? {
        bindings[marker]
    }

    func styleBindingTemplate(for value: String) -> (rendered: String, expression: String)? {
        var rendered = value
        var expression = value
        var foundBinding = false
        for (marker, binding) in bindings where rendered.contains(marker) {
            guard !binding.action else { continue }
            foundBinding = true
            rendered = rendered.replacingOccurrences(of: marker, with: binding.rendered)
            expression = expression.replacingOccurrences(
                of: marker, with: "{\(binding.expression)}")
        }
        return foundBinding ? (rendered, expression) : nil
    }

    func replaceAttributeBindings(_ tag: String) -> String {
        guard !bindings.isEmpty else { return tag }
        var output = ""
        var bound: [(name: String, expression: String)] = []
        var seen = Set<String>()
        var segmentStart = tag.startIndex
        var index = tag.startIndex
        while index < tag.endIndex {
            guard tag[index] == "_", let match = bindingMarker(in: tag, at: index),
                let binding = bindings[match.marker]
            else {
                index = tag.index(after: index)
                continue
            }
            output += tag[segmentStart..<index]
            output += escapeAttribute(binding.rendered)
            if !binding.action, seen.insert(match.marker).inserted,
                let attrName = attributeName(containing: match.marker, in: tag)
            {
                bound.append((attrName, binding.expression))
            }
            index = match.end
            segmentStart = index
        }
        guard segmentStart > tag.startIndex else { return tag }
        output += tag[segmentStart...]
        for binding in bound {
            output = setAttribute(
                "data-plume-bind-\(binding.name)", value: binding.expression, in: output)
        }
        return output
    }

    func replaceTextBindings(_ html: String) -> String {
        guard !bindings.isEmpty else { return html }
        var output = ""
        var segmentStart = html.startIndex
        var index = html.startIndex
        while index < html.endIndex {
            guard html[index] == "_", let match = bindingMarker(in: html, at: index),
                let binding = bindings[match.marker]
            else {
                index = html.index(after: index)
                continue
            }
            output += html[segmentStart..<index]
            if !binding.action {
                output +=
                    #"<span data-plume-text="\#(escapeAttribute(binding.expression))">\#(binding.rendered)</span>"#
            }
            index = match.end
            segmentStart = index
        }
        guard segmentStart > html.startIndex else { return html }
        output += html[segmentStart...]
        return output
    }

    func bindingMarker(in text: String, at start: String.Index) -> (
        marker: String, end: String.Index
    )? {
        guard text[start...].hasPrefix(Self.bindingMarkerPrefix) else { return nil }
        var cursor = text.index(start, offsetBy: Self.bindingMarkerPrefix.count)
        let digitsStart = cursor
        while cursor < text.endIndex, ("0"..."9").contains(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        guard cursor > digitsStart, text[cursor...].hasPrefix("__") else { return nil }
        let end = text.index(cursor, offsetBy: 2)
        return (String(text[start..<end]), end)
    }

    func attributeName(containing marker: String, in tag: String) -> String? {
        guard let markerRange = tag.range(of: marker) else { return nil }
        var cursor = markerRange.lowerBound
        while cursor > tag.startIndex {
            let previous = tag.index(before: cursor)
            if tag[previous] == "=" {
                let nameEnd = previous
                var nameStart = nameEnd
                while nameStart > tag.startIndex {
                    let before = tag.index(before: nameStart)
                    if tag[before].isWhitespace || tag[before] == "<" { break }
                    nameStart = before
                }
                let name = String(tag[nameStart..<nameEnd])
                return name.isEmpty ? nil : name
            }
            cursor = previous
        }
        return nil
    }

    func escapeAttribute(_ value: String) -> String {
        PlumeScanning.escapeHTML(value)
    }

    func capture(in string: NSString, match: NSTextCheckingResult, indexes: [Int]) -> String {
        for index in indexes where match.range(at: index).location != NSNotFound {
            return string.substring(with: match.range(at: index))
        }
        return ""
    }

    func truthyString(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "false" && trimmed != "nil" && trimmed != "null"
    }
}
