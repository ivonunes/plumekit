// Named routes: declare a path template once, then both REGISTER it and BUILD URLs
// from it — no hardcoded "/posts/\(id)" strings scattered through handlers and
// redirects, and renaming a path is a one-line change.
//
//     enum PostRoutes {
//         static let index = Route("/posts")
//         static let show = Route1("/posts/:id")
//     }
//
//     app.get(PostRoutes.index) { … }
//     app.get(PostRoutes.show) { … }
//
//     return .redirect(to: PostRoutes.show.path(post.id))     // "/posts/42"
//
// The parameter count is part of the type — `Route1.path` *requires* exactly one
// value, so a missing or extra parameter is a compile error, not a broken URL.
// Everything is byte-wise string assembly: Embedded-clean on every target.

/// A value that can fill a `:parameter` path segment.
public protocol PathParameter {
    var pathSegment: String { get }
}
extension Int: PathParameter { public var pathSegment: String { String(self) } }
extension Int64: PathParameter { public var pathSegment: String { String(self) } }
extension String: PathParameter {
    /// Percent-encode so a value with spaces / `/` / `?` / `%` stays a single valid path
    /// segment (the router percent-decodes on the way in, so it round-trips). Byte-wise,
    /// RFC 3986 unreserved set — embedded-clean.
    public var pathSegment: String {
        var out: [UInt8] = []
        let hex = Array("0123456789ABCDEF".utf8)
        for b in utf8 {
            let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
            if unreserved { out.append(b) }
            else { out.append(0x25); out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)]) }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
extension UUID: PathParameter { public var pathSegment: String { uuidString } }

/// Common shape for route values, so `app.get(_:)` and friends accept any arity.
public protocol RouteTemplate {
    var template: String { get }
}

/// A route with no path parameters: `Route("/posts")`.
public struct Route: RouteTemplate, Sendable {
    public let template: String
    public init(_ template: String) { self.template = template }

    /// The URL — for a parameterless route, the template itself.
    public var path: String { template }
}

/// A route with exactly one `:parameter`: `Route1("/posts/:id")`.
public struct Route1: RouteTemplate, Sendable {
    public let template: String
    public init(_ template: String) { self.template = template }

    /// The URL with the parameter filled in: `show.path(42)` → `"/posts/42"`.
    public func path(_ first: some PathParameter) -> String {
        fillParameters(template, [first.pathSegment])
    }
}

/// A route with exactly two `:parameters`: `Route2("/posts/:post_id/comments/:id")`.
public struct Route2: RouteTemplate, Sendable {
    public let template: String
    public init(_ template: String) { self.template = template }

    public func path(_ first: some PathParameter, _ second: some PathParameter) -> String {
        fillParameters(template, [first.pathSegment, second.pathSegment])
    }
}

/// Substitute `:segments` left to right. Byte-wise, no regex (Embedded-clean).
func fillParameters(_ template: String, _ values: [String]) -> String {
    var out: [UInt8] = []
    var next = 0
    let bytes = Array(template.utf8)
    var i = 0
    while i < bytes.count {
        if bytes[i] == 0x3A, i > 0, bytes[i - 1] == 0x2F {   // "/:" starts a parameter
            while i < bytes.count, bytes[i] != 0x2F { i += 1 }   // skip the segment name
            if next < values.count {
                out.append(contentsOf: Array(values[next].utf8))
                next += 1
            }
        } else {
            out.append(bytes[i]); i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

extension Application {
    /// Register a handler on a named route: `app.get(PostRoutes.show) { … }`.
    public func on(_ method: HTTPMethod, _ route: some RouteTemplate, _ handler: @escaping Responder) {
        on(method, route.template, handler)
    }
    public func get(_ route: some RouteTemplate, _ handler: @escaping Responder) { on(.get, route, handler) }
    public func post(_ route: some RouteTemplate, _ handler: @escaping Responder) { on(.post, route, handler) }
    public func put(_ route: some RouteTemplate, _ handler: @escaping Responder) { on(.put, route, handler) }
    public func patch(_ route: some RouteTemplate, _ handler: @escaping Responder) { on(.patch, route, handler) }
    public func delete(_ route: some RouteTemplate, _ handler: @escaping Responder) { on(.delete, route, handler) }
}
