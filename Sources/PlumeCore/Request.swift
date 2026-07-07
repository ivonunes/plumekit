/// Path parameters captured by the router, e.g. `:name` in `/hello/:name`.
///
/// Backed by pairs (not a `Dictionary`) — there are only ever a handful per
/// route, and pairs keep the type Embedded-clean and order-preserving.
public struct Parameters: Sendable {
    public private(set) var values: [(name: String, value: String)]

    public init() { self.values = [] }

    public subscript(_ name: String) -> String? {
        for v in values where utf8Equal(v.name, name) { return v.value }
        return nil
    }

    public mutating func set(_ name: String, _ value: String) {
        values.append((name: name, value: value))
    }
}

/// An incoming HTTP request, decoded by whichever adapter received it.
///
/// Bytes are `[UInt8]`, never `Data`, so `Request` is valid under Embedded Swift.
public struct Request: Sendable {
    /// `var` so method-override middleware can rewrite POST → PUT/PATCH/DELETE
    /// (from a `_method` field) before routing.
    public var method: HTTPMethod
    /// Path component only (no query string), percent-encoding left as received.
    public let path: String
    /// Raw query string after `?` (without the `?`), or empty.
    public let query: String
    public var headers: Headers
    public var body: [UInt8]
    /// Path parameters; populated by the router when a route matches.
    public var parameters: Parameters
    /// Per-request host capabilities (bindings, logging). Set by the adapter
    /// before dispatch; defaults to an empty context with no bindings.
    public var context: Context
    /// The authenticated identity, set by the identity middleware after
    /// resolving a cookie session or bearer token; nil when unauthenticated.
    public var principal: Principal?

    public init(
        method: HTTPMethod,
        path: String,
        query: String = "",
        headers: Headers = Headers(),
        body: [UInt8] = [],
        context: Context = .empty
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.parameters = Parameters()
        self.context = context
    }

    /// The body decoded as UTF-8 text (invalid sequences replaced).
    public var bodyText: String {
        decodeUTF8(body)
    }
}
