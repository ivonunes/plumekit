import Testing
@testable import PlumeCore
@testable import PlumeServer

// Streaming bodies through the portable seams: a buffered transport (the test
// client) collects streamed responses and replays buffered bodies into
// streaming routes — the native wire path is covered by the conformance suite.

@Suite struct StreamingBodyTests {
    @Test func streamedResponseCollectsOnBufferedTransports() async {
        let app = Application()
        app.get("/report") { _ in
            .stream(contentType: "text/csv") { writer in
                try await writer.write("id,name\n")
                try await writer.write([UInt8]("1,plume\n".utf8))
            }
        }

        let response = await TestHTTPClient(app).get("/report")
        #expect(response.status == 200)
        #expect(response.headers.first("content-type") == "text/csv")
        #expect(response.bodyText == "id,name\n1,plume\n")
    }

    @Test func streamedProducerErrorBecomesA500() async {
        struct Boom: Error {}
        let app = Application()
        app.get("/explode") { _ in
            .stream(contentType: "text/plain") { _ in throw Boom() }
        }
        let response = await TestHTTPClient(app).get("/explode")
        #expect(response.status == 500)
    }

    @Test func streamingRouteReplaysABufferedBody() async {
        let app = Application()
        app.post("/upload", body: .streaming) { request in
            #expect(request.body.isEmpty)   // the body only arrives via the reader
            var total = 0
            var chunks = 0
            while let chunk = try await request.bodyReader?.next() {
                total += chunk.count
                chunks += 1
            }
            return .text("\(total) bytes in \(chunks) chunk(s)")
        }

        let payload = [UInt8](repeating: 0x61, count: 10_000)
        let response = await TestHTTPClient(app).post("/upload", body: payload)
        #expect(response.bodyText == "10000 bytes in 1 chunk(s)")
    }

    @Test func emptyStreamingBodyReadsAsNoChunks() async {
        let app = Application()
        app.post("/upload", body: .streaming) { request in
            let first = try await request.bodyReader?.next()
            return .text(first == nil ? "empty" : "chunked")
        }
        let response = await TestHTTPClient(app).post("/upload", body: [])
        #expect(response.bodyText == "empty")
    }

    @Test func headDropsAStreamedBody() async {
        let app = Application()
        app.get("/report") { _ in
            .stream(contentType: "text/csv") { writer in try await writer.write("data") }
        }
        let response = await TestHTTPClient(app).send(.head, "/report")
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
    }
}

@Suite struct DevReloadInjectionTests {
    @Test func injectsBeforeClosingBody() {
        let response = Response.html("<html><body><h1>hi</h1></body></html>")
        let injected = DevReload.inject(into: response)
        let text = injected.bodyText
        #expect(text.contains("plumekit.dev.reload"))
        #expect(text.hasSuffix("</body></html>"))   // script sits before </body>
    }

    @Test func appendsWhenNoBodyTag() {
        let injected = DevReload.inject(into: .html("<p>fragment</p>"))
        #expect(injected.bodyText.contains("plumekit.dev.reload"))
    }

    @Test func leavesNonHTMLAndErrorsAlone() {
        #expect(!DevReload.inject(into: .json("{}")).bodyText.contains("plumekit"))
        #expect(!DevReload.inject(into: .html("nope", status: 404)).bodyText.contains("plumekit"))
    }
}
