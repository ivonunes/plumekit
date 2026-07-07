import Testing
@testable import PlumeCore
@testable import PlumeWorker

// Exercise the Wasm worker codec + async dispatch natively, so wire-format and
// dispatch bugs are caught here rather than only inside a wasm runtime.

private func encodeRequest(
    _ method: HTTPMethod,
    _ path: String,
    query: String = "",
    headers: [(String, String)] = [],
    body: [UInt8] = []
) -> [UInt8] {
    var w = ByteWriter()
    w.u8(method.rawValue)
    w.lengthPrefixedString(path)
    w.lengthPrefixedString(query)
    w.u16(headers.count)
    for (n, v) in headers { w.lengthPrefixedString(n); w.lengthPrefixedString(v) }
    w.u32(body.count)
    w.raw(body)
    return w.bytes
}

private func decodeResponse(_ bytes: [UInt8]) -> Response {
    var r = ByteReader(bytes)
    let status = r.u16() ?? 0
    let headerCount = r.u16() ?? 0
    var headers = Headers()
    var i = 0
    while i < headerCount {
        let nl = r.u16()!; let name = r.string(nl)!
        let vl = r.u16()!; let value = r.string(vl)!
        headers.add(name, value)
        i += 1
    }
    let bodyLen = r.u32() ?? 0
    return Response(status: status, headers: headers, body: r.take(bodyLen) ?? [])
}

@Test func decodeRequestRoundTrips() {
    let wire = encodeRequest(.get, "/hello/ada", query: "x=1", headers: [("host", "localhost")])
    let request = decodeRequest(wire)
    #expect(request != nil)
    #expect(request?.method == .get)
    #expect(request?.path == "/hello/ada")
    #expect(request?.query == "x=1")
    #expect(request?.headers.first("host") == "localhost")
}

@Test func processRequestDispatchesThroughTheRouter() async {
    let app = Application()
    app.get("/") { _ in .text("root") }
    app.get("/hello/:name") { req in .text("hi \(req.parameters["name"] ?? "?")") }

    let root = decodeResponse(await processRequest(app, encodeRequest(.get, "/"), context: .empty))
    #expect(root.status == 200)
    #expect(root.bodyText == "root")

    let hello = decodeResponse(await processRequest(app, encodeRequest(.get, "/hello/ada"), context: .empty))
    #expect(hello.bodyText == "hi ada")

    let missing = decodeResponse(await processRequest(app, encodeRequest(.get, "/missing"), context: .empty))
    #expect(missing.status == 404)
}

@Test func malformedRequestBlobIsBadRequest() async {
    let app = Application()
    let response = decodeResponse(await processRequest(app, [0xFF], context: .empty))
    #expect(response.status == 400)
}
