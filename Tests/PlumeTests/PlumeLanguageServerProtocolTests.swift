import XCTest

@testable import Plume

/// End-to-end JSON-RPC tests for PlumeLanguageServer, driven over in-memory
/// pipes the same way PlumeLanguageServerTests drives the server.
final class PlumeLanguageServerProtocolTests: XCTestCase {
    private let rootURI = "file:///nonexistent-plume-root"

    // MARK: - initialize

    func testInitializeReportsCapabilitiesAndServerInfo() throws {
        let messages = try runServer(input: [
            frame([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["rootUri": rootURI],
            ])
        ])

        let response = messages.first { $0["id"] as? Int == 1 }
        let result = response?["result"] as? [String: Any]
        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertEqual(capabilities?["textDocumentSync"] as? Int, 1)
        XCTAssertEqual(capabilities?["documentFormattingProvider"] as? Bool, true)
        XCTAssertEqual(capabilities?["documentSymbolProvider"] as? Bool, true)
        let completion = capabilities?["completionProvider"] as? [String: Any]
        let triggers = completion?["triggerCharacters"] as? [String]
        XCTAssertEqual(triggers?.contains("@"), true)
        XCTAssertEqual(triggers?.contains("|"), true)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "Plume")
    }

    // MARK: - diagnostics lifecycle

    func testDidOpenWithSyntaxErrorPublishesDiagnostics() throws {
        let uri = "file:///tmp/broken.plume"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: "@if broken {"),
        ])

        let diagnostics = publishedDiagnostics(in: messages, uri: uri)
        XCTAssertEqual(diagnostics.count, 1)
        let diagnostic = diagnostics.last?.first
        XCTAssertEqual((diagnostic?["message"] as? String)?.contains("Missing closing }"), true)
        XCTAssertEqual(diagnostic?["severity"] as? Int, 1)
        XCTAssertEqual(diagnostic?["source"] as? String, "plume")
        let range = diagnostic?["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        // The parser reports the missing } just past the opening brace
        // ("@if broken {" is 12 UTF-16 code units long).
        XCTAssertEqual(start?["line"] as? Int, 0)
        XCTAssertEqual(start?["character"] as? Int, 12)
        XCTAssertEqual(end?["line"] as? Int, 0)
        XCTAssertEqual(end?["character"] as? Int, 13)
    }

    func testDidChangeFixingTheErrorClearsDiagnostics() throws {
        let uri = "file:///tmp/fixable.plume"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: "@if broken {"),
            frame([
                "jsonrpc": "2.0", "method": "textDocument/didChange",
                "params": [
                    "textDocument": ["uri": uri, "version": 2],
                    "contentChanges": [["text": "@if broken {\n<p>ok</p>\n}"]],
                ],
            ]),
        ])

        let diagnostics = publishedDiagnostics(in: messages, uri: uri)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics.first?.isEmpty, false)
        XCTAssertEqual(diagnostics.last?.isEmpty, true)
    }

    func testDidCloseClearsDiagnostics() throws {
        let uri = "file:///tmp/closing.plume"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: "@if broken {"),
            frame([
                "jsonrpc": "2.0", "method": "textDocument/didClose",
                "params": ["textDocument": ["uri": uri]],
            ]),
        ])

        let diagnostics = publishedDiagnostics(in: messages, uri: uri)
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(diagnostics.first?.isEmpty, false)
        XCTAssertEqual(diagnostics.last?.isEmpty, true)
    }

    // MARK: - completion

    func testCompletionInsideExpressionOffersDirectivesFiltersAndContext() throws {
        let uri = "file:///tmp/completion.plume"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: "{site.title | }"),
            frame([
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
                "params": [
                    "textDocument": ["uri": uri],
                    "position": ["line": 0, "character": 14],
                ],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 2 }
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["isIncomplete"] as? Bool, false)
        let items = try XCTUnwrap(result?["items"] as? [[String: Any]])
        let labels = items.compactMap { $0["label"] as? String }
        XCTAssertTrue(labels.contains("default"), "filter completions expected")
        XCTAssertTrue(labels.contains("@component"), "directive completions expected")
        XCTAssertTrue(labels.contains("site"), "context completions expected")
        XCTAssertTrue(labels.contains("class:"), "attribute completions expected")
        let dateItem = items.first { $0["label"] as? String == "date" }
        XCTAssertEqual(dateItem?["insertTextFormat"] as? Int, 2, "snippets are marked as such")
    }

    // MARK: - documentSymbol

    func testDocumentSymbolListsComponentsStateLetsAndResources() throws {
        let uri = "file:///tmp/symbols.plume"
        let source = """
        @component Card(title) {
          <article>{title}</article>
        }
        @state expanded = false
        @let path = "/x/"
        @style {
          .a { color: red; }
        }
        """
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: source),
            frame([
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol",
                "params": ["textDocument": ["uri": uri]],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 2 }
        let symbols = try XCTUnwrap(response?["result"] as? [[String: Any]])
        let names = symbols.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("Card"))
        XCTAssertTrue(names.contains("expanded"))
        XCTAssertTrue(names.contains("path"))
        XCTAssertTrue(names.contains("style"))
        let card = symbols.first { $0["name"] as? String == "Card" }
        XCTAssertEqual(card?["detail"] as? String, "component")
        XCTAssertEqual(card?["kind"] as? Int, 5)
        let range = card?["range"] as? [String: Any]
        XCTAssertEqual((range?["start"] as? [String: Any])?["line"] as? Int, 0)
    }

    // MARK: - formatting

    func testFormattingReturnsSingleFullDocumentEdit() throws {
        let uri = "file:///tmp/format.plume"
        let source = "@if x {\n<p>y</p>\n}"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: source),
            frame([
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/formatting",
                "params": [
                    "textDocument": ["uri": uri],
                    "options": ["tabSize": 2, "insertSpaces": true],
                ],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 2 }
        let edits = try XCTUnwrap(response?["result"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?["newText"] as? String, PlumeFormatter.format(source))
        let range = edits.first?["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 0)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 2)
        XCTAssertEqual(end?["character"] as? Int, 1)
    }

    func testFormattingAFormattedDocumentReturnsNoEdits() throws {
        let uri = "file:///tmp/formatted.plume"
        let source = "@if x {\n  <p>y</p>\n}\n"
        XCTAssertEqual(PlumeFormatter.format(source), source, "fixture must be pre-formatted")
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            didOpenFrame(uri: uri, text: source),
            frame([
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/formatting",
                "params": ["textDocument": ["uri": uri]],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 2 }
        let edits = try XCTUnwrap(response?["result"] as? [[String: Any]])
        XCTAssertTrue(edits.isEmpty)
    }

    // MARK: - resilience and lifecycle

    func testUnknownMethodGetsNullResultAndServerKeepsServing() throws {
        let uri = "file:///tmp/resilient.plume"
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            frame([
                "jsonrpc": "2.0", "id": 5, "method": "workspace/executeCommand",
                "params": ["command": "doesNotExist"],
            ]),
            // Unknown notification (no id) must be ignored without a reply.
            frame(["jsonrpc": "2.0", "method": "workspace/didChangeNothing", "params": [:]]),
            didOpenFrame(uri: uri, text: "<p>ok</p>"),
            frame([
                "jsonrpc": "2.0", "id": 6, "method": "textDocument/documentSymbol",
                "params": ["textDocument": ["uri": uri]],
            ]),
        ])

        let unknown = messages.first { $0["id"] as? Int == 5 }
        XCTAssertNotNil(unknown, "Requests with unknown methods still get a response")
        XCTAssertTrue(unknown?["result"] is NSNull)
        XCTAssertNotNil(
            messages.first { $0["id"] as? Int == 6 },
            "Server keeps serving after an unknown method")
    }

    func testShutdownAndExitStopTheServer() throws {
        let messages = try runServer(input: [
            initializeFrame(id: 1),
            frame(["jsonrpc": "2.0", "id": 2, "method": "shutdown"]),
            frame(["jsonrpc": "2.0", "method": "exit"]),
            // Anything after exit must not be processed.
            frame(["jsonrpc": "2.0", "id": 99, "method": "initialize", "params": [:]]),
        ])

        let shutdownResponse = messages.first { $0["id"] as? Int == 2 }
        XCTAssertNotNil(shutdownResponse)
        XCTAssertTrue(shutdownResponse?["result"] is NSNull)
        XCTAssertNil(
            messages.first { $0["id"] as? Int == 99 },
            "Server must stop reading after exit")
    }

    // MARK: - Helpers

    private func initializeFrame(id: Int) -> Data {
        frame([
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": ["rootUri": rootURI],
        ])
    }

    private func didOpenFrame(uri: String, text: String) -> Data {
        frame([
            "jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "uri": uri,
                    "languageId": "plume",
                    "version": 1,
                    "text": text,
                ]
            ],
        ])
    }

    private func publishedDiagnostics(in messages: [[String: Any]], uri: String)
        -> [[[String: Any]]]
    {
        messages.compactMap { message in
            guard message["method"] as? String == "textDocument/publishDiagnostics",
                let params = message["params"] as? [String: Any],
                params["uri"] as? String == uri
            else {
                return nil
            }
            return params["diagnostics"] as? [[String: Any]] ?? []
        }
    }

    private func frame(_ object: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: object)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private func runServer(input frames: [Data]) throws -> [[String: Any]] {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let server = PlumeLanguageServer(
            input: inputPipe.fileHandleForReading,
            output: outputPipe.fileHandleForWriting
        )
        let finished = expectation(description: "server exited")
        let runningServer = UncheckedSendable(value: server)
        Thread.detachNewThread {
            runningServer.value.run()
            outputPipe.fileHandleForWriting.closeFile()
            finished.fulfill()
        }
        for frame in frames {
            inputPipe.fileHandleForWriting.write(frame)
        }
        inputPipe.fileHandleForWriting.closeFile()
        wait(for: [finished], timeout: 10)
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return parseFrames(data)
    }

    private func parseFrames(_ data: Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var cursor = data.startIndex
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = data[cursor...].range(of: separator) {
            let header = String(data: data[cursor..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            guard
                let lengthLine = header.components(separatedBy: "\r\n").first(where: {
                    $0.lowercased().hasPrefix("content-length:")
                }),
                let length = Int(
                    lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
            else {
                break
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = data.index(bodyStart, offsetBy: length)
            if let object = try? JSONSerialization.jsonObject(with: data[bodyStart..<bodyEnd])
                as? [String: Any]
            {
                messages.append(object)
            }
            cursor = bodyEnd
        }
        return messages
    }
}
