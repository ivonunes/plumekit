import Foundation

public enum PlumeFormatter {
    public static func format(_ source: String, indent: String = "  ") -> String {
        let lines = source.components(separatedBy: .newlines)
        var depth = 0
        var rawDirectiveBraceDepth: Int?
        var output: [String] = []

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if output.last?.isEmpty != true {
                    output.append("")
                }
                continue
            }

            if let currentRawDirectiveDepth = rawDirectiveBraceDepth {
                // Inside a raw @style/@script/@navigation block: emit verbatim, do
                // not canonicalise (it's CSS/JS, not Plume expressions).
                let nextRawDirectiveDepth = currentRawDirectiveDepth + braceDelta(line)
                let lineDepth = nextRawDirectiveDepth == 0 ? max(0, depth - 1) : depth
                output.append(String(repeating: indent, count: lineDepth) + line)
                rawDirectiveBraceDepth = nextRawDirectiveDepth == 0 ? nil : nextRawDirectiveDepth
                if nextRawDirectiveDepth == 0 {
                    depth = max(0, depth - 1)
                }
                continue
            }

            line = canonicalize(line)

            if closesPlumeBlock(line) {
                depth = max(0, depth - 1)
            }

            output.append(String(repeating: indent, count: depth) + line)

            if opensRawDirectiveBlock(line) {
                depth += 1
                rawDirectiveBraceDepth = braceDelta(line)
                if rawDirectiveBraceDepth == 0 {
                    depth = max(0, depth - 1)
                    rawDirectiveBraceDepth = nil
                }
                continue
            }

            if opensPlumeBlock(line), !closesPlumeBlock(line) {
                depth += 1
            } else if line.hasPrefix("} else"), line.hasSuffix("{") {
                depth += 1
            }
        }

        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// One canonical, Swift-spelled name per transform. Both the alias and the
    /// canonical name keep parsing; the formatter rewrites to the canonical form.
    private static let canonicalNames: [String: String] = [
        "upcase": "uppercased",
        "downcase": "lowercased",
        "startsWith": "hasPrefix",
        "endsWith": "hasSuffix",
        "slug": "slugify",
        "replacing": "replace",
        "null": "nil",
        "blank": "empty",
    ]

    private static func canonicalize(_ line: String) -> String {
        // Never touch raw directive headers (their bodies are CSS/JS).
        if line.hasPrefix("@style") || line.hasPrefix("@script") || line.hasPrefix("@navigation") {
            return line
        }
        var result = renameIdentifiers(line)
        // One slot-naming form: `@slot(name: x)` -> `@slot(x)` (same for @content).
        result = result.replacingOccurrences(
            of: #"@(slot|content)\(\s*name\s*:\s*"#, with: "@$1(", options: .regularExpression)
        return result
    }

    /// Replaces whole-identifier alias tokens with their canonical name, leaving
    /// the contents of string literals untouched.
    private static func renameIdentifiers(_ line: String) -> String {
        var output = ""
        var quote: Character?
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let active = quote {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == active { quote = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                output.append(character)
                index += 1
                continue
            }
            if character.isLetter || character == "_" {
                var token = ""
                while index < characters.count,
                    characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_"
                {
                    token.append(characters[index])
                    index += 1
                }
                output.append(canonicalNames[token] ?? token)
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func opensRawDirectiveBlock(_ line: String) -> Bool {
        line.range(of: #"^@(style|script|navigation)(?:\s*\([^)]*\))?\s*\{$"#, options: .regularExpression) != nil
    }

    private static func braceDelta(_ line: String) -> Int {
        line.reduce(0) { total, character in
            if character == "{" { return total + 1 }
            if character == "}" { return total - 1 }
            return total
        }
    }

    private static func opensPlumeBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("{") else { return false }
        return trimmed.hasPrefix("@if ")
            || trimmed.hasPrefix("@for ")
            || trimmed.hasPrefix("@component ")
            || trimmed.hasPrefix("@comment")
            || trimmed.hasPrefix("@slot")
            || trimmed.hasPrefix("@content")
            || trimmed.hasPrefix("} else")
            || trimmed.range(of: #"^@[A-Z][A-Za-z0-9_]*\(.*\)\s*\{$"#, options: .regularExpression) != nil
    }

    private static func closesPlumeBlock(_ line: String) -> Bool {
        line == "}" || line.hasPrefix("} else")
    }
}
