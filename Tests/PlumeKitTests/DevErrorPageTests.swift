import Testing
@testable import PlumeServer
import PlumeCore

@Suite struct DevErrorPageTests {
    struct SampleError: Error, CustomStringConvertible {
        var description: String { "database <disk> is full & unhappy" }
    }

    private func makeRequest() -> Request {
        var headers = Headers()
        headers.add("host", "localhost:8080")
        headers.add("x-token", "<secret>")
        return Request(method: .post, path: "/posts", query: "draft=1",
                       headers: headers, body: Array("title=Hello & <World>".utf8),
                       context: .empty)
    }

    @Test func rendersErrorTypeMessageAndRequest() {
        let response = DevErrorPage.response(
            error: SampleError(), request: makeRequest(),
            routes: [(method: "GET", path: "/posts"), (method: "POST", path: "/posts")])
        let html = String(decoding: response.body, as: UTF8.self)

        #expect(response.status == 500)
        #expect(response.headers.first("content-type")?.contains("text/html") == true)
        #expect(html.contains("SampleError"))
        #expect(html.contains("database &lt;disk&gt; is full &amp; unhappy"))   // escaped
        #expect(html.contains("POST"))
        #expect(html.contains("/posts"))
        #expect(html.contains("draft=1"))
        #expect(html.contains("title=Hello &amp; &lt;World&gt;"))               // body preview, escaped
        #expect(html.contains("&lt;secret&gt;"))                                 // header value escaped
        #expect(!html.contains("<secret>"))                                      // never raw
    }

    @Test func escapeNeutralizesMarkup() {
        #expect(DevErrorPage.escape(#"<script>"a" & 'b'</script>"#)
            == "&lt;script&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/script&gt;")
    }
}
