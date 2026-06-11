import Foundation

enum PlumeScanning {
    static func splitExpression(
        _ expression: String, separator: String, skippingLogicalPipes: Bool = false
    ) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                current.append(character)
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "(" {
                parenDepth += 1
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "[" {
                bracketDepth += 1
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
                index = expression.index(after: index)
                continue
            }
            if parenDepth == 0, bracketDepth == 0, expression[index...].hasPrefix(separator),
                !(skippingLogicalPipes && isLogicalPipe(in: expression, at: index, separator: separator))
            {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                index = expression.index(index, offsetBy: separator.count)
                continue
            }
            current.append(character)
            index = expression.index(after: index)
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    static func isLogicalPipe(in expression: String, at index: String.Index, separator: String) -> Bool {
        guard separator == "|" else { return false }
        let next = expression.index(after: index)
        if next < expression.endIndex, expression[next] == "|" { return true }
        if index > expression.startIndex {
            let previous = expression.index(before: index)
            if expression[previous] == "|" { return true }
        }
        return false
    }

    static func topLevelIndex(of needle: Character, in expression: String) -> String.Index? {
        var quote: Character?
        var parenDepth = 0
        var bracketDepth = 0
        var index = expression.startIndex
        while index < expression.endIndex {
            let character = expression[index]
            if let quoteCharacter = quote {
                if character == quoteCharacter { quote = nil }
                index = expression.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = expression.index(after: index)
                continue
            }
            if character == "(" {
                parenDepth += 1
            } else if character == ")" {
                parenDepth = max(0, parenDepth - 1)
            } else if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if character == needle, parenDepth == 0, bracketDepth == 0 {
                return index
            }
            index = expression.index(after: index)
        }
        return nil
    }

    static func escapeHTML(_ value: String) -> String {
        guard value.contains(where: needsHTMLEscape) else { return value }
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": output += "&amp;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.append(character)
            }
        }
        return output
    }

    static func escapeHTMLOnce(_ value: String) -> String {
        guard value.contains(where: needsHTMLEscape) else { return value }
        var output = ""
        output.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            switch character {
            case "&": output += isHTMLEntity(value, at: index) ? "&" : "&amp;"
            case "\"": output += "&quot;"
            case "'": output += "&#39;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.append(character)
            }
            index = value.index(after: index)
        }
        return output
    }

    static func suggestion(for value: String, in candidates: [String]) -> String {
        guard let best = candidates.min(by: { levenshtein(value, $0) < levenshtein(value, $1) })
        else {
            return ""
        }
        return levenshtein(value, best) <= 3 ? " Did you mean \(best)?" : ""
    }

    static func levenshtein(_ left: String, _ right: String) -> Int {
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

    private static func needsHTMLEscape(_ character: Character) -> Bool {
        character == "&" || character == "\"" || character == "'" || character == "<"
            || character == ">"
    }

    private static func isHTMLEntity(_ value: String, at ampersand: String.Index) -> Bool {
        var index = value.index(after: ampersand)
        guard index < value.endIndex else { return false }
        if value[index] == "#" {
            index = value.index(after: index)
            var isHexadecimal = false
            if index < value.endIndex, value[index] == "x" {
                isHexadecimal = true
                index = value.index(after: index)
            }
            let digitsStart = index
            while index < value.endIndex,
                isHexadecimal ? isASCIIHexDigit(value[index]) : isASCIIDigit(value[index])
            {
                index = value.index(after: index)
            }
            return index > digitsStart && index < value.endIndex && value[index] == ";"
        }
        let lettersStart = index
        while index < value.endIndex, isASCIILetter(value[index]) {
            index = value.index(after: index)
        }
        return index > lettersStart && index < value.endIndex && value[index] == ";"
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        isASCIIDigit(character) || ("a"..."f").contains(character)
            || ("A"..."F").contains(character)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("A"..."Z").contains(character)
    }
}

final class PlumeMemoCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Value] = [:]
    private let limit: Int

    init(limit: Int = 4096) {
        self.limit = limit
    }

    func cachedValue(for key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ value: Value, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < limit else { return }
        storage[key] = value
    }

    func value(for key: String, compute: () -> Value) -> Value {
        if let cached = cachedValue(for: key) { return cached }
        let value = compute()
        store(value, for: key)
        return value
    }
}

final class PlumeRegexCache: @unchecked Sendable {
    static let shared = PlumeRegexCache()

    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        storage[pattern] = regex
        return regex
    }
}
