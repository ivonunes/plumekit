import Foundation

extension PlumeRenderer {
    mutating func applyFilter(_ name: String, arguments: [String], to value: Any?) throws -> Any? {
        let evaluated = try arguments.map { try evaluate($0) }
        switch name {
        case "default":
            return truthy(value) ? value : argument(evaluated)
        case "date":
            return formatDate(value, format: argument(evaluated).map(stringify))
        case "dateToXMLSchema":
            return formatDate(value, dateFormat: "yyyy-MM-dd'T'HH:mm:ssXXXXX")
        case "dateToRFC822":
            return formatDate(value, dateFormat: "EEE, dd MMM yyyy HH:mm:ss Z")
        case "dateToString":
            return formatDate(value, dateFormat: "dd MMM yyyy")
        case "dateToLongString":
            return formatDate(value, dateFormat: "dd MMMM yyyy")
        case "split":
            return stringify(value).components(separatedBy: stringify(argument(evaluated)))
        case "last":
            return (value as? [Any])?.last
        case "first":
            return (value as? [Any])?.first
        case "map":
            guard let key = argument(evaluated).map(stringify), let values = value as? [Any] else {
                return []
            }
            return values.map { propertyPath(key, of: $0) ?? NSNull() }
        case "where":
            guard let key = argument(evaluated).map(stringify), let values = value as? [Any] else {
                return []
            }
            let expected = argument(evaluated, at: 1)
            return values.filter { item in
                let property = propertyPath(key, of: item)
                guard let expected else { return truthy(property) }
                return stringify(property) == stringify(expected)
            }
        case "sort", "sortNatural":
            guard let values = value as? [Any] else { return value }
            let key = argument(evaluated).map(stringify)
            return values.sorted { left, right in
                let leftValue = stringify(key.flatMap { propertyPath($0, of: left) } ?? left)
                let rightValue = stringify(key.flatMap { propertyPath($0, of: right) } ?? right)
                if name == "sortNatural" {
                    return leftValue.localizedStandardCompare(rightValue) == .orderedAscending
                }
                return leftValue < rightValue
            }
        case "reverse":
            if let values = value as? [Any] { return Array(values.reversed()) }
            return String(stringify(value).reversed())
        case "unique":
            guard let values = value as? [Any] else { return value }
            var seen = Set<String>()
            return values.filter { seen.insert(stringify($0)).inserted }
        case "compact":
            guard let values = value as? [Any] else { return value }
            return values.filter { !($0 is NSNull) }
        case "concat":
            guard let values = value as? [Any] else { return value }
            if let other = argument(evaluated) as? [Any] { return values + other }
            if let other = argument(evaluated) { return values + [other] }
            return values
        case "join":
            return (value as? [Any])?.map(stringify).joined(
                separator: stringify(argument(evaluated)))
        case "replace":
            return try applyMethod("replace", arguments: arguments, to: value)
        case "replaceFirst":
            return try applyMethod("replaceFirst", arguments: arguments, to: value)
        case "remove":
            return stringify(value).replacingOccurrences(
                of: stringify(argument(evaluated)), with: "")
        case "removeFirst":
            return replaceFirst(
                stringify(value), target: stringify(argument(evaluated)), replacement: "")
        case "append":
            return stringify(value) + stringify(argument(evaluated))
        case "prepend":
            return stringify(argument(evaluated)) + stringify(value)
        case "upcase":
            return stringify(value).uppercased()
        case "downcase":
            return stringify(value).lowercased()
        case "capitalize":
            let text = stringify(value).lowercased()
            guard let first = text.first else { return text }
            return first.uppercased() + String(text.dropFirst())
        case "strip":
            return stringify(value).trimmingCharacters(in: .whitespacesAndNewlines)
        case "lstrip":
            return stringify(value).replacingOccurrences(
                of: #"^\s+"#, with: "", options: .regularExpression)
        case "rstrip":
            return stringify(value).replacingOccurrences(
                of: #"\s+$"#, with: "", options: .regularExpression)
        case "stripNewlines":
            return stringify(value).replacingOccurrences(of: "\n", with: "").replacingOccurrences(
                of: "\r", with: "")
        case "newlineToBR":
            return PlumeSafeHTML(
                escapeHTML(stringify(value)).replacingOccurrences(of: "\n", with: "<br>\n"))
        case "stripHTML":
            return stringify(value).replacingOccurrences(
                of: #"<[^>]+>"#, with: "", options: .regularExpression)
        case "urlEncode":
            return urlEncode(stringify(value))
        case "urlDecode":
            return stringify(value).removingPercentEncoding ?? stringify(value)
        case "json":
            return PlumeSafeHTML(jsonString(value))
        case "slice":
            return slice(
                value, start: Int(number(argument(evaluated))),
                length: argument(evaluated, at: 1).map { Int(number($0)) })
        case "truncate":
            return truncate(
                stringify(value), length: Int(number(argument(evaluated) ?? 50)),
                omission: argument(evaluated, at: 1).map(stringify) ?? "...")
        case "truncateWords":
            return truncateWords(
                stringify(value), count: Int(number(argument(evaluated) ?? 15)),
                omission: argument(evaluated, at: 1).map(stringify) ?? "...")
        case "slugify", "slug":
            return slugify(stringify(value))
        case "size":
            return size(of: value)
        case "abs":
            return numeric(abs(number(value)))
        case "ceil":
            return numeric(ceil(number(value)))
        case "floor":
            return numeric(floor(number(value)))
        case "round":
            let precision = max(0, Int(number(argument(evaluated) ?? 0)))
            let multiplier = pow(10.0, Double(precision))
            return numeric((number(value) * multiplier).rounded() / multiplier)
        case "plus":
            return numeric(number(value) + number(argument(evaluated)))
        case "minus":
            return numeric(number(value) - number(argument(evaluated)))
        case "times":
            return numeric(number(value) * number(argument(evaluated)))
        case "dividedBy":
            let divisor = number(argument(evaluated))
            return divisor == 0 ? 0 : numeric(number(value) / divisor)
        case "modulo":
            let divisor = number(argument(evaluated))
            return divisor == 0
                ? 0 : numeric(number(value).truncatingRemainder(dividingBy: divisor))
        case "atLeast":
            return numeric(max(number(value), number(argument(evaluated))))
        case "atMost":
            return numeric(min(number(value), number(argument(evaluated))))
        default:
            throw PlumeError.template(
                "Unsupported Plume filter: \(name).\(suggestion(for: name, in: knownFilters))")
        }
    }

    var knownMethods: [String] {
        [
            "contains", "startsWith", "hasPrefix", "endsWith", "hasSuffix", "replace", "replacing",
            "replaceFirst", "split", "lowercased", "downcase", "uppercased", "upcase", "slugify",
            "slug",
        ]
    }

    var knownFilters: [String] {
        [
            "default", "date", "dateToXMLSchema", "dateToRFC822", "dateToString",
            "dateToLongString",
            "split", "last", "first", "map", "where", "sort", "sortNatural", "reverse", "unique",
            "compact",
            "concat", "join", "replace", "replaceFirst", "remove", "removeFirst", "append",
            "prepend",
            "upcase", "downcase", "capitalize", "strip", "lstrip", "rstrip", "stripNewlines",
            "newlineToBR",
            "stripHTML", "urlEncode", "urlDecode", "json", "slice", "truncate", "truncateWords",
            "slugify", "slug",
            "size", "abs", "ceil", "floor", "round", "plus", "minus", "times", "dividedBy",
            "modulo",
            "atLeast", "atMost", "raw", "escape", "escape_once",
        ]
    }

    func jsonString(_ value: Any?) -> String {
        let ready = jsonReady(value)
        let isRootObject = JSONSerialization.isValidJSONObject(ready)
        let root: Any = isRootObject ? ready : [ready]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        guard !isRootObject, json.count >= 2 else {
            return json
        }
        return String(json.dropFirst().dropLast())
    }

    func jsonReady(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let safe = value as? PlumeSafeHTML { return safe.html }
        if value is String || value is Bool || value is Int || value is Double || value is Float {
            return value
        }
        if let values = value as? [Any] {
            return values.map(jsonReady)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(jsonReady)
        }
        return stringify(value)
    }

    func suggestion(for value: String, in candidates: [String]) -> String {
        guard let best = candidates.min(by: { levenshtein(value, $0) < levenshtein(value, $1) })
        else {
            return ""
        }
        return levenshtein(value, best) <= 3 ? " Did you mean \(best)?" : ""
    }

    func levenshtein(_ left: String, _ right: String) -> Int {
        let left = Array(left)
        let right = Array(right)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for (leftIndex, leftCharacter) in left.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    func parseFilter(_ filter: String) -> (name: String, arguments: [String]) {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), trimmed.last == ")" else {
            return (trimmed, [])
        }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentsStart = trimmed.index(after: open)
        let arguments = String(trimmed[argumentsStart..<trimmed.index(before: trimmed.endIndex)])
        return (name, splitExpression(arguments, separator: ",").filter { !$0.isEmpty })
    }
}
