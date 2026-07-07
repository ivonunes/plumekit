import Foundation

// `plumekit mcp` — a Model Context Protocol server over stdio that gives AI coding
// agents accurate access to PlumeKit (its APIs, the project's config, and the docs).
// Speaks newline-delimited JSON-RPC 2.0 and exposes tools:
//   • api_reference(topic)  — a curated, accurate reference for a core API (embedded,
//                             so it works offline in any project).
//   • project_info()        — the current project's plumekit.toml (capabilities/targets).
//   • search_docs(query)    — search the framework docs (embedded, so it works without
//                             a checkout; a live checkout is preferred when present).
//
// Point an agent at it with, e.g., a Claude Code MCP config: `{"command":"./plumekit",
// "args":["mcp"]}`.
enum MCPServer {
    static func run() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handle(message)
        }
        return 0
    }

    // MARK: - Dispatch

    private static func handle(_ message: [String: Any]) {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "plumekit", "version": "2.0.0"],
                "instructions": "PlumeKit is a Swift web framework. Use the `api_reference` tool for accurate PlumeKit APIs before writing code.",
            ])
        case "notifications/initialized", "notifications/cancelled":
            break   // notifications get no response
        case "ping":
            respond(id: id, result: [:])
        case "tools/list":
            respond(id: id, result: ["tools": toolDefinitions])
        case "tools/call":
            handleToolCall(id: id, params: message["params"] as? [String: Any] ?? [:])
        default:
            if id != nil { respondError(id: id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private static func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let text: String
        switch name {
        case "api_reference":
            let topic = (arguments["topic"] as? String)?.lowercased() ?? ""
            text = APIReference.topics[topic]
                ?? "Unknown topic '\(topic)'. Available topics: \(APIReference.topics.keys.sorted().joined(separator: ", "))."
        case "project_info":
            text = projectInfo()
        case "search_docs":
            text = searchDocs(query: arguments["query"] as? String ?? "")
        default:
            respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
            return
        }
        respond(id: id, result: ["content": [["type": "text", "text": text]]])
    }

    // MARK: - Tools

    private static var toolDefinitions: [[String: Any]] { [
        [
            "name": "api_reference",
            "description": "Accurate reference for a core PlumeKit API. Call this before writing PlumeKit code. Topics: \(APIReference.topics.keys.sorted().joined(separator: ", ")).",
            "inputSchema": [
                "type": "object",
                "properties": ["topic": ["type": "string", "description": "One of: \(APIReference.topics.keys.sorted().joined(separator: ", "))"]],
                "required": ["topic"],
            ],
        ],
        [
            "name": "project_info",
            "description": "The current PlumeKit project's plumekit.toml: enabled capabilities, build/deploy config, and per-target drivers.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "search_docs",
            "description": "Search the PlumeKit documentation for a query and return matching sections.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
    ] }

    private static func projectInfo() -> String {
        guard let toml = try? String(contentsOfFile: "plumekit.toml", encoding: .utf8) else {
            return "No plumekit.toml in the current directory — run from a PlumeKit project root."
        }
        return "Current project's plumekit.toml:\n\n```toml\n\(toml)\n```"
    }

    private static func searchDocs(query: String) -> String {
        // Prefer the live docs/ when a framework checkout is locatable (fresh during
        // framework development); otherwise use the docs EMBEDDED in the binary, so
        // search works for a standalone (brew/tarball) install with no checkout.
        let files = liveDocs() ?? DocsEmbedded.files
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "No matches." }
        var hits: [(file: String, snippet: String)] = []
        for (name, content) in files {
            let lowered = content.lowercased()
            guard terms.allSatisfy({ lowered.contains($0) }) else { continue }
            // A short snippet around the first term match. Search `content` itself
            // case-insensitively — a `lowered` index is NOT valid on `content` when
            // lowercasing changes byte length (e.g. `İ` → `i̇`), which would mis-slice.
            if let range = content.range(of: terms[0], options: .caseInsensitive) {
                let start = content.index(range.lowerBound, offsetBy: -80, limitedBy: content.startIndex) ?? content.startIndex
                let end = content.index(range.upperBound, offsetBy: 240, limitedBy: content.endIndex) ?? content.endIndex
                hits.append((name, String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if hits.count >= 6 { break }
        }
        if hits.isEmpty { return "No docs matched '\(query)'." }
        return hits.map { "## docs/\($0.file)\n\n…\($0.snippet)…" }.joined(separator: "\n\n")
    }

    /// The live docs/ tree when a framework checkout is locatable (via PLUMEKIT_PATH or
    /// a binary sitting inside a checkout), else nil so the caller falls back to the
    /// embedded copy.
    private static func liveDocs() -> [(name: String, content: String)]? {
        guard let root = frameworkRoot(),
              let enumerator = FileManager.default.enumerator(atPath: root + "/docs") else { return nil }
        var files: [(name: String, content: String)] = []
        for case let path as String in enumerator where path.hasSuffix(".md") {
            if let content = try? String(contentsOfFile: root + "/docs/" + path, encoding: .utf8) {
                files.append((path, content))
            }
        }
        // Sort by path so the live result order matches the embedded copy (which the
        // build-time PlumeEmbed plugin sorts) — same top-N for the same query on both.
        return files.isEmpty ? nil : files.sorted { $0.name < $1.name }
    }

    // MARK: - JSON-RPC I/O

    private static func respond(id: Any?, result: [String: Any]) {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        message["id"] = id ?? NSNull()
        write(message)
    }

    private static func respondError(id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": code, "message": message]])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
