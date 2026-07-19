/// In-process HTTP client for endpoint tests.
///
/// It exercises the same `Application.handle(_:)` path as server/worker
/// adapters, but without binding a socket or starting a real web server.
public struct TestHTTPClient: Sendable {
    public let app: Application
    public let context: Context
    /// A browser-style cookie jar: `Set-Cookie` responses persist and are sent back
    /// as `Cookie` on subsequent requests, so session and CSRF flows test naturally.
    public let jar: CookieJar

    public init(_ app: Application, context: Context = .empty) {
        self.app = app
        self.context = context
        self.jar = CookieJar()
    }

    public func send(
        _ method: HTTPMethod,
        _ target: String,
        headers: Headers = Headers(),
        body: [UInt8] = []
    ) async -> Response {
        let split = splitTarget(target)
        var withCookies = headers
        if withCookies.first("cookie") == nil, let cookies = jar.cookieHeader() {
            withCookies.set("cookie", cookies)
        }
        let request = Request(
            method: method,
            path: split.path,
            query: split.query,
            headers: withCookies,
            body: body,
            context: context
        )
        var response = await app.handle(request)
        // Tests assert on bytes, so a streamed body is materialised here; a
        // producer error surfaces as the 500 it would be natively.
        do {
            response = try await response.collectingStream()
        } catch {
            response = Response.text("500 Internal Server Error", status: 500)
        }
        for setCookie in response.headers.all("set-cookie") { jar.store(setCookie) }
        return response
    }

    public func get(_ target: String, headers: Headers = Headers()) async -> Response {
        await send(.get, target, headers: headers)
    }

    public func post(_ target: String, headers: Headers = Headers(), body: [UInt8] = []) async -> Response {
        await send(.post, target, headers: headers, body: body)
    }

    public func put(_ target: String, headers: Headers = Headers(), body: [UInt8] = []) async -> Response {
        await send(.put, target, headers: headers, body: body)
    }

    public func patch(_ target: String, headers: Headers = Headers(), body: [UInt8] = []) async -> Response {
        await send(.patch, target, headers: headers, body: body)
    }

    public func delete(_ target: String, headers: Headers = Headers()) async -> Response {
        await send(.delete, target, headers: headers)
    }

    public func head(_ target: String, headers: Headers = Headers()) async -> Response {
        await send(.head, target, headers: headers)
    }

    public func options(_ target: String, headers: Headers = Headers()) async -> Response {
        await send(.options, target, headers: headers)
    }

    public func post(_ target: String, text: String, headers: Headers = Headers()) async -> Response {
        await send(.post, target, headers: headers, body: encodeUTF8(text))
    }

    public func post(_ target: String, json: JSONValue, headers: Headers = Headers()) async -> Response {
        var h = headers
        if h.first("content-type") == nil { h.set("content-type", "application/json") }
        if h.first("accept") == nil { h.set("accept", "application/json") }
        return await send(.post, target, headers: h, body: json.serialize())
    }

    public func put(_ target: String, json: JSONValue, headers: Headers = Headers()) async -> Response {
        var h = headers
        if h.first("content-type") == nil { h.set("content-type", "application/json") }
        if h.first("accept") == nil { h.set("accept", "application/json") }
        return await send(.put, target, headers: h, body: json.serialize())
    }

    public func patch(_ target: String, json: JSONValue, headers: Headers = Headers()) async -> Response {
        var h = headers
        if h.first("content-type") == nil { h.set("content-type", "application/json") }
        if h.first("accept") == nil { h.set("accept", "application/json") }
        return await send(.patch, target, headers: h, body: json.serialize())
    }

    public func postForm(_ target: String, _ form: String, headers: Headers = Headers()) async -> Response {
        var h = headers
        if h.first("content-type") == nil {
            h.set("content-type", "application/x-www-form-urlencoded")
        }
        return await send(.post, target, headers: h, body: encodeUTF8(form))
    }

    /// Form POST from name/value pairs. Values are percent-encoded here — a test
    /// never hand-assembles `a=b&c=d` or forgets to escape an `&` inside a value.
    public func postForm(_ target: String, fields: [(String, String)],
                         headers: Headers = Headers()) async -> Response {
        await postForm(target, TestHTTPClient.encodeFormFields(fields), headers: headers)
    }

    /// application/x-www-form-urlencoded via the shared `percentEncode` (spaces
    /// travel as `%20`; `FormParams` decodes `%XX` and `+` alike).
    static func encodeFormFields(_ fields: [(String, String)]) -> String {
        var encoded = ""
        for (name, value) in fields {
            if !encoded.isEmpty { encoded += "&" }
            encoded += decodeUTF8(percentEncode(Array(name.utf8))) + "="
                + decodeUTF8(percentEncode(Array(value.utf8)))
        }
        return encoded
    }
}

extension Response {
    /// Parse the response body as JSON, or nil if it is not valid JSON.
    public var jsonBody: JSONValue? { parseJSON(body) }
}

/// The client's cookie store. A reference type so the value-typed client shares one
/// jar across requests. Test-only, single-task use.
public final class CookieJar: @unchecked Sendable {
    private var cookies: [(name: String, value: String)] = []

    public init() {}

    /// Pre-seed a cookie (e.g. a fixed CSRF visitor value in a test harness).
    public func set(_ name: String, _ value: String) {
        cookies.removeAll { $0.name == name }
        cookies.append((name, value))
    }

    public func value(_ name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    /// Record a `Set-Cookie` header value: stores the pair, honoring deletions
    /// (`Max-Age=0` or an empty value removes the cookie).
    func store(_ setCookie: String) {
        let parts = setCookie.split(separator: ";", omittingEmptySubsequences: true)
        guard let pair = parts.first, let eq = pair.firstIndex(of: "=") else { return }
        let name = String(pair[..<eq]).trimmingWhitespace()
        let value = String(pair[pair.index(after: eq)...]).trimmingWhitespace()
        let attributes = parts.dropFirst().map { String($0).trimmingWhitespace().lowercased() }
        if value.isEmpty || attributes.contains("max-age=0") {
            cookies.removeAll { $0.name == name }
        } else {
            set(name, value)
        }
    }

    func cookieHeader() -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

private extension String {
    func trimmingWhitespace() -> String {
        var bytes = Array(utf8)
        while bytes.first == 0x20 || bytes.first == 0x09 { bytes.removeFirst() }
        while bytes.last == 0x20 || bytes.last == 0x09 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private func splitTarget(_ target: String) -> (path: String, query: String) {
    var path: [UInt8] = []
    var query: [UInt8] = []
    var inQuery = false
    for byte in target.utf8 {
        if !inQuery && byte == 0x3f {
            inQuery = true
            continue
        }
        if inQuery { query.append(byte) } else { path.append(byte) }
    }
    return (decodeUTF8(path.isEmpty ? [0x2f] : path), decodeUTF8(query))
}
