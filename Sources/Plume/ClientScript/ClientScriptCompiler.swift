import Foundation

struct ClientScriptCompiler {
    let source: String
    let sourceName: String?
    let lines: [String]
    var output: [String] = []
    var indent = 0
    var blocks: [ClientScriptBlock] = []
    var usesClassHelper = false

    init(source: String, sourceName: String?) {
        self.source = source
        self.sourceName = sourceName
        self.lines = source.components(separatedBy: .newlines)
    }

    mutating func compile() throws -> String {
        if let runtime = browserRuntimeScript() {
            return runtime
        }
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("//") {
                emit(trimmed)
                continue
            }
            try compile(line: trimmed, rawLine: rawLine, lineNumber: lineNumber)
        }
        if !blocks.isEmpty {
            throw error("Missing closing } in @script block.", line: lines.count, sourceLine: lines.last ?? source)
        }
        var compiled = output.joined(separator: "\n")
        if usesClassHelper {
            compiled = """
            function __plumeClasses(value) { return String(value ?? "").split(/\\s+/).filter(Boolean); }
            \(compiled)
            """
        }
        return compiled + "\n"
    }

    func compileBrowserRuntime() -> String {
        let compiled = transformBrowserRuntimeScript(source.trimmingCharacters(in: .whitespacesAndNewlines))
        return compiled + "\n"
    }
}
