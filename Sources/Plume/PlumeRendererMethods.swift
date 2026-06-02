import Foundation

extension PlumeRenderer {
    mutating func applyMethod(_ name: String, arguments: [String], to value: Any?) throws -> Any? {
        let evaluated = try arguments.map { try evaluate($0) }
        switch name {
        case "contains":
            let needle = stringify(argument(evaluated))
            if let array = value as? [Any] { return array.map(stringify).contains(needle) }
            return stringify(value).contains(needle)
        case "startsWith", "hasPrefix":
            return stringify(value).hasPrefix(stringify(argument(evaluated)))
        case "endsWith", "hasSuffix":
            return stringify(value).hasSuffix(stringify(argument(evaluated)))
        case "replace", "replacing":
            let target = stringify(argument(evaluated))
            guard !target.isEmpty else { return stringify(value) }
            return stringify(value).replacingOccurrences(
                of: target, with: stringify(argument(evaluated, at: 1)))
        case "replaceFirst":
            return replaceFirst(
                stringify(value), target: stringify(argument(evaluated)),
                replacement: stringify(argument(evaluated, at: 1)))
        case "split":
            return stringify(value).components(separatedBy: stringify(argument(evaluated)))
        case "lowercased", "downcase":
            return stringify(value).lowercased()
        case "uppercased", "upcase":
            return stringify(value).uppercased()
        case "slugify", "slug":
            return slugify(stringify(value))
        default:
            throw PlumeError.template(
                "Unsupported Plume method: \(name).\(suggestion(for: name, in: knownMethods))")
        }
    }
}
