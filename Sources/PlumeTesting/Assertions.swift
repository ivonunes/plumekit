import PlumeCore

// Response assertions that read well inside `#expect`, plus an auth-header helper.
//
//     #expect(response.hasStatus(201))
//     #expect(response.bodyContains("created"))
//     #expect(response.isRedirect)
//     let me = await app.client.get("/me", headers: .bearer(token))

extension Response {
    public func hasStatus(_ code: Int) -> Bool { status == code }
    public var isOK: Bool { status == 200 }
    public var isSuccessful: Bool { status >= 200 && status < 300 }
    public var isRedirect: Bool { status >= 300 && status < 400 }
    public func bodyContains(_ text: String) -> Bool { bodyText.contains(text) }
    public func header(_ name: String) -> String? { headers.first(name) }
    public var redirectLocation: String? { headers.first("location") }

    /// The response body parsed as JSON, or nil.
    public func decodedJSON() -> JSONValue? { parseJSON(body) }
}

extension Headers {
    /// Headers carrying `Authorization: Bearer <token>` — for authenticated test requests
    /// (log in / register to get a token, then pass it here).
    public static func bearer(_ token: String) -> Headers {
        var headers = Headers()
        headers.add("authorization", "Bearer " + token)
        return headers
    }
}
