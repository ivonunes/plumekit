import Foundation

extension PlumeRenderer {
    func numeric(_ value: Double) -> Any {
        value.rounded() == value ? Int(value) : value
    }

    func size(of value: Any?) -> Int {
        if let array = value as? [Any] { return array.count }
        if let dictionary = value as? [String: Any] { return dictionary.count }
        return stringify(value).count
    }

    func replaceFirst(_ value: String, target: String, replacement: String) -> String {
        guard !target.isEmpty, let range = value.range(of: target) else { return value }
        return value.replacingCharacters(in: range, with: replacement)
    }

    func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    func slice(_ value: Any?, start: Int, length: Int?) -> Any {
        if let values = value as? [Any] {
            let range = sliceRange(count: values.count, start: start, length: length)
            return Array(values[range])
        }
        let characters = Array(stringify(value))
        let range = sliceRange(count: characters.count, start: start, length: length)
        return String(characters[range])
    }

    func sliceRange(count: Int, start: Int, length: Int?) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = max(0, start < 0 ? count + start : start)
        guard lower < count else { return count..<count }
        let upper = min(count, lower + max(0, length ?? 1))
        return lower..<upper
    }

    func truncate(_ value: String, length: Int, omission: String) -> String {
        guard length > 0, value.count > length else { return value }
        let visibleCount = max(0, length - omission.count)
        return String(value.prefix(visibleCount)) + omission
    }

    func truncateWords(_ value: String, count: Int, omission: String) -> String {
        let words = value.split(whereSeparator: { $0.isWhitespace })
        guard count > 0, words.count > count else { return value }
        return words.prefix(count).joined(separator: " ") + omission
    }

    func slugify(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func formatDate(_ value: Any?, format: String?) -> String {
        let requested = format ?? "yyyy-MM-dd"
        let dateFormat = requested.contains("%") ? liquidDateFormat(requested) : requested
        return formatDate(value, dateFormat: dateFormat)
    }

    func formatDate(_ value: Any?, dateFormat: String) -> String {
        guard let date = date(from: value) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    func date(from value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let int = value as? Int { return Date(timeIntervalSince1970: TimeInterval(int)) }
        if let double = value as? Double { return Date(timeIntervalSince1970: double) }
        let text = stringify(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "now" || text == "today" { return Date() }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    func liquidDateFormat(_ format: String) -> String {
        var output = ""
        var literal = ""
        var index = format.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            output += "'\(literal.replacingOccurrences(of: "'", with: "''"))'"
            literal = ""
        }

        while index < format.endIndex {
            let character = format[index]
            guard character == "%" else {
                literal.append(character)
                index = format.index(after: index)
                continue
            }

            flushLiteral()
            index = format.index(after: index)
            guard index < format.endIndex else {
                literal.append("%")
                break
            }

            var noPadding = false
            while index < format.endIndex, "-_0".contains(format[index]) {
                if format[index] == "-" { noPadding = true }
                index = format.index(after: index)
            }
            guard index < format.endIndex else { break }

            let token = format[index]
            output += dateToken(token, noPadding: noPadding) ?? "'%\(token)'"
            index = format.index(after: index)
        }

        flushLiteral()
        return output
    }

    func dateToken(_ token: Character, noPadding: Bool) -> String? {
        switch token {
        case "a": return "EEE"
        case "A": return "EEEE"
        case "b": return "MMM"
        case "B": return "MMMM"
        case "d": return noPadding ? "d" : "dd"
        case "e": return "d"
        case "m": return noPadding ? "M" : "MM"
        case "Y": return "yyyy"
        case "y": return "yy"
        case "H": return noPadding ? "H" : "HH"
        case "k": return "H"
        case "I": return noPadding ? "h" : "hh"
        case "l": return "h"
        case "M": return "mm"
        case "S": return "ss"
        case "p", "P": return "a"
        case "z": return "Z"
        case "Z": return "zzz"
        case "F": return "yyyy-MM-dd"
        case "T": return "HH:mm:ss"
        case "R": return "HH:mm"
        case "D": return "MM/dd/yy"
        case "%": return "'%'"
        default: return nil
        }
    }
}
