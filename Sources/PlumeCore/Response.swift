/// An HTTP response produced by a handler or middleware.
///
/// `status` is a plain `Int`; values stay well within range on both 64-bit
/// native builds and 32-bit wasm. The body is `[UInt8]` to remain Embedded-clean.
public struct Response: Sendable {
    public var status: Int
    public var headers: Headers
    public var body: [UInt8]
    /// A body produced incrementally instead of `body` — see `Response.stream`.
    /// Adapters that can stream do; buffered transports collect it first.
    public var bodyStream: (@Sendable (ResponseBodyWriter) async throws -> Void)?

    public init(status: Int = 200, headers: Headers = Headers(), body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyStream = nil
    }

    /// The body decoded as UTF-8 text (invalid sequences replaced).
    public var bodyText: String {
        decodeUTF8(body)
    }

    // MARK: Convenience constructors

    /// The freshness default for dynamic responses. Without an explicit
    /// Cache-Control, browsers cache heuristically and serve stale pages after
    /// deploys (a cached page references content-hashed assets that no longer
    /// exist). Override per response with `headers.set("cache-control", …)`.
    static let defaultCacheControl = "private, max-age=0, must-revalidate"

    /// A `text/plain; charset=utf-8` response.
    public static func text(_ string: String, status: Int = 200) -> Response {
        var headers = Headers()
        headers.set("content-type", "text/plain; charset=utf-8")
        headers.set("cache-control", defaultCacheControl)
        return Response(status: status, headers: headers, body: encodeUTF8(string))
    }

    /// A `text/html; charset=utf-8` response.
    public static func html(_ string: String, status: Int = 200) -> Response {
        var headers = Headers()
        headers.set("content-type", "text/html; charset=utf-8")
        headers.set("cache-control", defaultCacheControl)
        return Response(status: status, headers: headers, body: encodeUTF8(string))
    }

    /// A `text/html; charset=utf-8` response from pre-rendered UTF-8 bytes.
    ///
    /// This is the seam a view layer renders into: e.g. a Plume render function
    /// fills an `HTML` buffer, and its `.bytes` become the response body — no
    /// extra copy through `String`, and the core stays view-engine-agnostic.
    public static func html(bytes: [UInt8], status: Int = 200) -> Response {
        var headers = Headers()
        headers.set("content-type", "text/html; charset=utf-8")
        headers.set("cache-control", defaultCacheControl)
        return Response(status: status, headers: headers, body: bytes)
    }

    /// A response carrying a pre-serialized JSON string.
    public static func json(_ string: String, status: Int = 200) -> Response {
        var headers = Headers()
        headers.set("content-type", "application/json; charset=utf-8")
        headers.set("cache-control", defaultCacheControl)
        return Response(status: status, headers: headers, body: encodeUTF8(string))
    }

    /// A response serialized from a `JSONValue` (reflection-free).
    public static func json(_ value: JSONValue, status: Int = 200) -> Response {
        var headers = Headers()
        headers.set("content-type", "application/json; charset=utf-8")
        headers.set("cache-control", defaultCacheControl)
        return Response(status: status, headers: headers, body: value.serialize())
    }

    /// A bare status response with an empty body (e.g. 404, 204).
    public static func status(_ status: Int) -> Response {
        Response(status: status)
    }

    /// A redirect (303 See Other by default — the POST-redirect-GET pattern).
    public static func redirect(to location: String, status: Int = 303) -> Response {
        var headers = Headers()
        headers.set("location", location)
        return Response(status: status, headers: headers)
    }

    /// Reason phrase for common status codes; falls back to a generic phrase.
    public var reasonPhrase: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default:
            if status >= 200 && status < 300 { return "OK" }
            if status >= 400 && status < 500 { return "Client Error" }
            if status >= 500 { return "Server Error" }
            return "Unknown"
        }
    }
}
