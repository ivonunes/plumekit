import Foundation

public enum PlumeFormatter {
    public static func format(_ source: String, indent: String = "  ") -> String {
        let lines = source.components(separatedBy: .newlines)
        var depth = 0
        var rawDirectiveBraceDepth: Int?
        var output: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if output.last?.isEmpty != true {
                    output.append("")
                }
                continue
            }

            if let currentRawDirectiveDepth = rawDirectiveBraceDepth {
                let nextRawDirectiveDepth = currentRawDirectiveDepth + braceDelta(line)
                let lineDepth = nextRawDirectiveDepth == 0 ? max(0, depth - 1) : depth
                output.append(String(repeating: indent, count: lineDepth) + line)
                rawDirectiveBraceDepth = nextRawDirectiveDepth == 0 ? nil : nextRawDirectiveDepth
                if nextRawDirectiveDepth == 0 {
                    depth = max(0, depth - 1)
                }
                continue
            }

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
