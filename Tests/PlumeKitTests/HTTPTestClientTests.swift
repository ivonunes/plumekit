import Testing
@testable import PlumeCore

@Test func testHTTPClientCallsEndpointsInProcess() async {
    let app = Application()
    app.post("/echo") { request in
        #expect(request.query == "mode=json")
        #expect(request.hasJSONBody)
        #expect(request.wantsJSON)
        return .json(.object([
            (name: "path", value: .string(request.path)),
            (name: "name", value: request.json()?["name"] ?? .null),
        ]), status: 201)
    }

    let client = TestHTTPClient(app)
    let response = await client.post("/echo?mode=json", json: .object([
        (name: "name", value: .string("Ada")),
    ]))

    #expect(response.status == 201)
    #expect(response.jsonBody?["path"]?.stringValue == "/echo")
    #expect(response.jsonBody?["name"]?.stringValue == "Ada")
}

@Test func testHTTPClientSendsFormBodies() async {
    let app = Application()
    app.post("/submit") { request in
        #expect(request.headers.first("content-type") == "application/x-www-form-urlencoded")
        return .text(request.form["title"] ?? "")
    }

    let response = await TestHTTPClient(app).postForm("/submit", "title=Hello+World")
    #expect(response.status == 200)
    #expect(response.bodyText == "Hello World")
}

@Test func postFormFieldsArePercentEncoded() async {
    let app = Application()
    app.post("/submit") { request in
        // Values with &, =, + and non-ASCII round-trip through the encoder.
        .text((request.form["a"] ?? "") + "|" + (request.form["b"] ?? ""))
    }

    let response = await TestHTTPClient(app).postForm("/submit", fields: [
        ("a", "one & two = three"),
        ("b", "café+snake"),
    ])
    #expect(response.bodyText == "one & two = three|café+snake")
}
