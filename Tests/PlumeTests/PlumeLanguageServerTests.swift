import XCTest

@testable import Plume

final class PlumeLanguageServerTests: XCTestCase {
    func testServerSkipsMalformedFramesAndKeepsRunning() throws {
        let messages = try runServer(input: [
            Data("Content-Length: 5\r\n\r\nnotjs".utf8),
            frame([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["rootUri": "file:///nonexistent-plume-root"],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 1 }
        XCTAssertNotNil(response, "Server should still answer after a malformed frame")
        XCTAssertNotNil((response?["result"] as? [String: Any])?["capabilities"])
    }

    func testDiagnosticPositionsUseUTF16CodeUnits() throws {
        let source = "🙂🙂 {{legacy}}"
        let messages = try runServer(input: [
            frame([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["rootUri": "file:///nonexistent-plume-root"],
            ]),
            frame([
                "jsonrpc": "2.0", "method": "textDocument/didOpen",
                "params": [
                    "textDocument": [
                        "uri": "file:///tmp/utf16.plume",
                        "languageId": "plume",
                        "version": 1,
                        "text": source,
                    ]
                ],
            ]),
        ])

        let notification = messages.first {
            $0["method"] as? String == "textDocument/publishDiagnostics"
        }
        let diagnostics = (notification?["params"] as? [String: Any])?["diagnostics"]
            as? [[String: Any]]
        let start = ((diagnostics?.first?["range"] as? [String: Any])?["start"]) as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 0)
        XCTAssertEqual(start?["character"] as? Int, 5)
    }

    func testCompletionReplacementRangeUsesUTF16CodeUnits() throws {
        let source = "🙂🙂 @co"
        let messages = try runServer(input: [
            frame([
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["rootUri": "file:///nonexistent-plume-root"],
            ]),
            frame([
                "jsonrpc": "2.0", "method": "textDocument/didOpen",
                "params": [
                    "textDocument": [
                        "uri": "file:///tmp/utf16-completion.plume",
                        "languageId": "plume",
                        "version": 1,
                        "text": source,
                    ]
                ],
            ]),
            frame([
                "jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
                "params": [
                    "textDocument": ["uri": "file:///tmp/utf16-completion.plume"],
                    "position": ["line": 0, "character": 8],
                ],
            ]),
        ])

        let response = messages.first { $0["id"] as? Int == 2 }
        let items = ((response?["result"] as? [String: Any])?["items"]) as? [[String: Any]]
        let component = items?.first { $0["label"] as? String == "@component" }
        let range = (component?["textEdit"] as? [String: Any])?["range"] as? [String: Any]
        XCTAssertEqual((range?["start"] as? [String: Any])?["character"] as? Int, 5)
        XCTAssertEqual((range?["end"] as? [String: Any])?["character"] as? Int, 8)
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
            guard let lengthLine = header.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }),
                let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
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
