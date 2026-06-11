import Foundation

extension ClientScriptCompiler {
    func browserRuntimeScript() -> String? {
        guard let directiveIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        guard lines[directiveIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "@browserRuntime" else {
            return nil
        }
        var output = lines
        output.remove(at: directiveIndex)
        let source = output
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transformBrowserRuntimeScript(source) + "\n"
    }

    func transformBrowserRuntimeScript(_ source: String) -> String {
        var output: [String] = []
        var braceDepth = 0
        var classBodyDepths: [Int] = []
        for rawLine in source.components(separatedBy: .newlines) {
            classBodyDepths.removeAll { braceDepth < $0 }
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let indentation = String(rawLine.prefix { $0 == " " || $0 == "\t" })
            var line = rawLine
            let enteringClass = trimmed.range(of: #"^class\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*:\s*[A-Za-z_][A-Za-z0-9_]*)?\s*\{"#, options: .regularExpression) != nil
            let insideClass = !classBodyDepths.isEmpty
            line = line.replacingOccurrences(of: #"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*\{"#, with: "class $1 extends $2 {", options: .regularExpression)
            if insideClass {
                line = line.replacingOccurrences(of: #"^(\s*)async\s+func\s+"#, with: "$1async ", options: .regularExpression)
                line = line.replacingOccurrences(of: #"^(\s*)func\s+"#, with: "$1", options: .regularExpression)
                line = line.replacingOccurrences(of: #"^(\s*)init\s*\("#, with: "$1constructor(", options: .regularExpression)
            } else if trimmed.hasPrefix("async func ") {
                line = indentation + line.dropFirst(indentation.count).replacingOccurrences(of: "async func ", with: "async function ", options: [], range: nil)
            } else if trimmed.hasPrefix("func ") {
                line = indentation + line.dropFirst(indentation.count).replacingOccurrences(of: "func ", with: "function ", options: [], range: nil)
            }
            line = line.replacingOccurrences(of: #"\basync\s+func\s*\("#, with: "async function(", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\bfunc\s*\("#, with: "function(", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\bself\."#, with: "this.", options: .regularExpression)
            output.append(line)
            let delta = braceDelta(in: line)
            if enteringClass {
                classBodyDepths.append(braceDepth + 1)
            }
            braceDepth = max(0, braceDepth + delta)
        }
        return output.joined(separator: "\n")
    }

    func braceDelta(in line: String) -> Int {
        var quote: Character?
        var delta = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let quoteCharacter = quote {
                if character == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex {
                        index = line.index(after: index)
                    }
                    continue
                }
                if character == quoteCharacter {
                    quote = nil
                }
                index = line.index(after: index)
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
            index = line.index(after: index)
        }
        return delta
    }
}
