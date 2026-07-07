import Testing
@testable import PlumeCore
@testable import PlumeServer

@Test func parsesContentLengthAndBodyBoundary() {
    let raw = Array("PUT /kv/x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nABCDE".utf8)
    let head = parseRequestHead(raw)
    #expect(head != nil)
    #expect(head?.method == .put)
    #expect(head?.path == "/kv/x")
    #expect(head?.headers.fields.map { $0.name } == ["Host", "Content-Length", "Connection"])
    #expect(head?.headers.first("content-length") == "5")
    #expect(head?.contentLength == 5)
    // Body should begin right after the header terminator.
    if let head {
        let body = Array(raw[head.headerByteCount...])
        #expect(body == Array("ABCDE".utf8))
    }
}
