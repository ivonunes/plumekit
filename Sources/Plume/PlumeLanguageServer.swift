import Foundation

public final class PlumeLanguageServer {
    private let input: FileHandle
    private let output: FileHandle
    private let fileManager: FileManager
    private var documents: [String: String] = [:]
    private var rootURL: URL?
    private var shouldExit = false

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        fileManager: FileManager = .default
    ) {
        self.input = input
        self.output = output
        self.fileManager = fileManager
    }

    public func run() {
        while !shouldExit, let message = readMessage() {
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            rootURL = rootURL(from: params)
            respond(id: id, result: initializeResult())
        case "initialized":
            return
        case "shutdown":
            respond(id: id, result: NSNull())
        case "exit":
            shouldExit = true
        case "textDocument/didOpen":
            if let document = params["textDocument"] as? [String: Any],
               let uri = document["uri"] as? String,
               let text = document["text"] as? String {
                documents[uri] = text
                publishDiagnostics(uri: uri, source: text)
            }
        case "textDocument/didChange":
            if let document = params["textDocument"] as? [String: Any],
               let uri = document["uri"] as? String,
               let changes = params["contentChanges"] as? [[String: Any]],
               let text = changes.last?["text"] as? String {
                documents[uri] = text
                publishDiagnostics(uri: uri, source: text)
            }
        case "textDocument/didSave":
            if let uri = textDocumentURI(from: params),
               let source = source(for: uri) {
                publishDiagnostics(uri: uri, source: source)
            }
        case "textDocument/didClose":
            if let uri = textDocumentURI(from: params) {
                documents.removeValue(forKey: uri)
                sendNotification("textDocument/publishDiagnostics", params: ["uri": uri, "diagnostics": []])
            }
        case "textDocument/formatting":
            guard let uri = textDocumentURI(from: params), let source = source(for: uri) else {
                respond(id: id, result: [])
                return
            }
            let formatted = PlumeLanguageSupport.format(source)
            let edits: [[String: Any]] = formatted == source ? [] : [
                [
                    "range": fullDocumentRange(source),
                    "newText": formatted
                ]
            ]
            respond(id: id, result: edits)
        case "textDocument/completion":
            respond(id: id, result: [
                "isIncomplete": false,
                "items": PlumeLanguageSupport.completions().map { completionItem($0, params: params) }
            ])
        case "textDocument/documentSymbol":
            guard let uri = textDocumentURI(from: params), let source = source(for: uri) else {
                respond(id: id, result: [])
                return
            }
            respond(id: id, result: PlumeLanguageSupport.symbols(in: source).map(symbolItem))
        case "$/cancelRequest":
            return
        default:
            if id != nil {
                respond(id: id, result: NSNull())
            }
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "capabilities": [
                "textDocumentSync": 1,
                "completionProvider": [
                    "triggerCharacters": ["@", "{", "|", ".", ":"]
                ],
                "documentFormattingProvider": true,
                "documentSymbolProvider": true
            ],
            "serverInfo": [
                "name": "Plume",
                "version": "1.0.0"
            ]
        ]
    }

    private func publishDiagnostics(uri: String, source: String) {
        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: source,
            sourceName: sourceName(for: uri),
            componentSources: componentSources(currentURI: uri)
        )
        sendNotification("textDocument/publishDiagnostics", params: [
            "uri": uri,
            "diagnostics": diagnostics.map { diagnosticItem($0, source: source) }
        ])
    }

    private func componentSources(currentURI: String) -> [String: String] {
        var sources: [String: String] = documents.reduce(into: [:]) { result, entry in
            guard entry.key != currentURI else { return }
            result[sourceName(for: entry.key)] = entry.value
        }

        guard let rootURL else { return sources }
        let currentPath = fileURL(from: currentURI)?.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return sources
        }

        for case let file as URL in enumerator {
            if shouldSkipDirectory(file) {
                enumerator.skipDescendants()
                continue
            }
            guard file.standardizedFileURL.path != currentPath,
                  file.pathExtension == "plume",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let source = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let name = relativePath(file, root: rootURL)
            sources[name] = source
        }
        return sources
    }

    private func shouldSkipDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return false
        }
        return [".build", ".cache", ".git", "dist", "node_modules"].contains(url.lastPathComponent)
    }

    private func completionItem(_ completion: PlumeCompletion, params: [String: Any]) -> [String: Any] {
        var item: [String: Any] = [
            "label": completion.label,
            "detail": completion.detail,
            "insertText": completion.insertText,
            "kind": completion.kind
        ]
        if completion.isSnippet {
            item["insertTextFormat"] = 2
        }
        if let range = completionReplacementRange(for: completion, params: params) {
            item.removeValue(forKey: "insertText")
            item["textEdit"] = [
                "range": range,
                "newText": completion.insertText
            ]
        }
        return item
    }

    private func completionReplacementRange(for completion: PlumeCompletion, params: [String: Any]) -> [String: Any]? {
        guard completion.label.hasPrefix("@"),
              let uri = textDocumentURI(from: params),
              let source = source(for: uri),
              let position = params["position"] as? [String: Any],
              let lineIndex = position["line"] as? Int,
              let character = position["character"] as? Int,
              let lineText = line(at: lineIndex, in: source) else {
            return nil
        }

        let end = min(max(0, character), lineText.count)
        let prefix = String(lineText.prefix(end))
        let tokenStart = directiveTokenStart(in: prefix)
        return [
            "start": ["line": lineIndex, "character": tokenStart],
            "end": ["line": lineIndex, "character": end]
        ]
    }

    private func directiveTokenStart(in prefix: String) -> Int {
        var start = prefix.count
        for character in prefix.reversed() {
            if character == "@" || character == "_" || character.isLetter || character.isNumber {
                start -= 1
            } else {
                break
            }
        }
        return start
    }

    private func diagnosticItem(_ diagnostic: PlumeDiagnostic, source: String) -> [String: Any] {
        let lineIndex = max(0, diagnostic.line - 1)
        let columnIndex = max(0, diagnostic.column - 1)
        let lineText = line(at: lineIndex, in: source) ?? diagnostic.sourceLine
        let endColumn = min(max(columnIndex + 1, columnIndex), max(lineText.count, columnIndex + 1))
        return [
            "range": [
                "start": ["line": lineIndex, "character": columnIndex],
                "end": ["line": lineIndex, "character": endColumn]
            ],
            "severity": diagnostic.severity.rawValue,
            "source": "plume",
            "message": diagnostic.message
        ]
    }

    private func symbolItem(_ symbol: PlumeDocumentSymbol) -> [String: Any] {
        let line = max(0, symbol.line - 1)
        let character = max(0, symbol.column - 1)
        let range: [String: Any] = [
            "start": ["line": line, "character": character],
            "end": ["line": line, "character": character + max(1, symbol.name.count)]
        ]
        return [
            "name": symbol.name,
            "detail": symbol.detail,
            "kind": symbol.kind,
            "range": range,
            "selectionRange": range
        ]
    }

    private func fullDocumentRange(_ source: String) -> [String: Any] {
        let lines = source.components(separatedBy: .newlines)
        return [
            "start": ["line": 0, "character": 0],
            "end": ["line": max(0, lines.count - 1), "character": lines.last?.count ?? 0]
        ]
    }

    private func source(for uri: String) -> String? {
        if let cached = documents[uri] { return cached }
        guard let url = fileURL(from: uri) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func textDocumentURI(from params: [String: Any]) -> String? {
        (params["textDocument"] as? [String: Any])?["uri"] as? String
    }

    private func sourceName(for uri: String) -> String {
        guard let url = fileURL(from: uri) else { return uri }
        if let rootURL {
            return relativePath(url, root: rootURL)
        }
        return url.lastPathComponent
    }

    private func rootURL(from params: [String: Any]) -> URL? {
        if let rootURI = params["rootUri"] as? String,
           let url = fileURL(from: rootURI) {
            return url
        }
        if let folders = params["workspaceFolders"] as? [[String: Any]],
           let uri = folders.first?["uri"] as? String {
            return fileURL(from: uri)
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }

    private func fileURL(from uri: String) -> URL? {
        if let url = URL(string: uri), url.isFileURL {
            return url
        }
        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri)
        }
        return nil
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return path
            .dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func line(at line: Int, in source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        guard line >= 0, line < lines.count else { return nil }
        return lines[line]
    }

    private func respond(id: Any?, result: Any) {
        guard let id else { return }
        send([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private func sendNotification(_ method: String, params: [String: Any]) {
        send([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return
        }
        output.write(Data("Content-Length: \(body.count)\r\n\r\n".utf8))
        output.write(body)
    }

    private func readMessage() -> [String: Any]? {
        guard let header = readHeader(),
              let length = contentLength(in: header) else {
            return nil
        }
        let body = input.readData(ofLength: length)
        guard body.count == length,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func readHeader() -> String? {
        var data = Data()
        let terminator = Data([13, 10, 13, 10])
        while true {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            data.append(byte)
            if data.count >= terminator.count, data.suffix(terminator.count) == terminator {
                return String(data: data, encoding: .utf8)
            }
        }
    }

    private func contentLength(in header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1])
            }
        }
        return nil
    }
}
