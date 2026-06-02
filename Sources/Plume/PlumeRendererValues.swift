import Foundation

extension PlumeRenderer {
    func resolve(_ path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        var value: Any?
        for scope in scopes.reversed() where scope.keys.contains(first) {
            value = scope[first]
            break
        }
        if value == nil { value = locals[first] }
        if value == nil { value = root[first] }
        for part in parts.dropFirst() {
            value = property(part, of: value)
        }
        return value
    }

    mutating func set(_ name: String, to value: Any) {
        if scopes.isEmpty {
            locals[name] = value
        } else {
            scopes[scopes.count - 1][name] = value
        }
    }

    func forloop(index: Int, count: Int) -> [String: Any] {
        [
            "index": index + 1,
            "index0": index,
            "rindex": count - index,
            "rindex0": count - index - 1,
            "first": index == 0,
            "last": index == count - 1,
            "length": count,
        ]
    }

    func property(_ name: String, of value: Any?) -> Any? {
        guard let value else { return nil }
        if name == "size" || name == "count" {
            if let array = value as? [Any] { return array.count }
            if let dictionary = value as? [String: Any] { return dictionary.count }
            if let string = value as? String { return string.count }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary[name]
        }
        if let array = value as? [Any], let index = Int(name), array.indices.contains(index) {
            return array[index]
        }
        return nil
    }

    func propertyPath(_ path: String, of value: Any?) -> Any? {
        var current = value
        for part in path.split(separator: ".").map(String.init) {
            current = property(part, of: current)
        }
        return current
    }

    func argument(_ arguments: [Any?], at index: Int = 0) -> Any? {
        guard arguments.indices.contains(index) else { return nil }
        return arguments[index]
    }

    func truthy(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let double = value as? Double { return double != 0 }
        if let string = value as? String { return !string.isEmpty && string != "false" }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }

    mutating func compare(left: Any?, op: String, right: Any?) throws -> Bool {
        switch op {
        case "==": return stringify(left) == stringify(right)
        case "!=": return stringify(left) != stringify(right)
        case ">": return number(left) > number(right)
        case "<": return number(left) < number(right)
        case ">=": return number(left) >= number(right)
        case "<=": return number(left) <= number(right)
        default: return false
        }
    }

    func number(_ value: Any?) -> Double {
        if let int = value as? Int { return Double(int) }
        if let double = value as? Double { return double }
        if let string = value as? String, let double = Double(string) { return double }
        return 0
    }

    func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if let safe = value as? PlumeSafeHTML { return safe.html }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        if let array = value as? [Any] {
            return array.map(stringify).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return String(describing: value)
    }

    func isSafeHTML(_ value: Any?) -> Bool {
        value is PlumeSafeHTML
    }

    func referencesState(_ expression: String) -> Bool {
        for name in stateNames {
            if expression.range(
                of:
                    #"(?<![A-Za-z0-9_])\#(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z0-9_])"#,
                options: .regularExpression) != nil
            {
                return true
            }
        }
        return false
    }
}
