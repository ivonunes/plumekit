/// One segment of a route pattern.
///
/// Literals are stored as UTF-8 bytes so matching is byte-for-byte — `String`
/// equality would pull Unicode normalization tables into the embedded-wasm link.
enum PathSegment {
    /// A fixed segment that must match exactly, e.g. `hello`.
    case literal([UInt8])
    /// A capture segment like `:name`, binding the matched segment to `name`.
    case parameter(String)
    /// A catch-all like `*path` (one or more segments) or `**path` (zero or more) —
    /// must be the last segment; binds the rest of the path, slash-joined, to `name`.
    case wildcard(String, allowEmpty: Bool)
}

/// A registered route: an HTTP method, a parsed path pattern, its handler, and
/// how it takes its request body.
struct RegisteredRoute {
    let method: HTTPMethod
    let pattern: [PathSegment]
    let handler: Responder
    let bodyMode: RequestBodyMode
}

/// The outcome of matching a request against the route table.
public enum RouteMatch {
    /// A route matched; carries its handler, the captured path parameters, and
    /// the route's request-body mode.
    case found(Responder, Parameters, RequestBodyMode)
    /// The path matched one or more routes, but none for this method.
    case methodNotAllowed
    /// No route matched the path at all.
    case notFound
}

/// HTTP method + path matching with path parameters.
///
/// Deliberately simple and allocation-light: routes are matched by walking a
/// flat list and comparing pre-parsed segments as UTF-8 bytes. No regex, no
/// Foundation, no `String` comparison — valid (and linkable) under Embedded Swift.
public struct Router {
    private var routes: [RegisteredRoute] = []

    public init() {}

    /// The registered routes as (method, path) pairs — for tooling (`plumekit routes`).
    public var descriptions: [(method: String, path: String)] {
        routes.map { route in
            var path = ""
            for segment in route.pattern {
                switch segment {
                case .literal(let bytes): path += "/" + decodeUTF8(bytes)
                case .parameter(let name): path += "/:" + name
                case .wildcard(let name, let allowEmpty): path += "/" + (allowEmpty ? "**" : "*") + name
                }
            }
            return (route.method.name, path.isEmpty ? "/" : path)
        }
    }

    /// Register `handler` for `method` at `path` (e.g. `/hello/:name`).
    public mutating func add(_ method: HTTPMethod, _ path: String, _ handler: @escaping Responder,
                             bodyMode: RequestBodyMode = .buffered) {
        routes.append(RegisteredRoute(method: method, pattern: Router.parse(path),
                                      handler: handler, bodyMode: bodyMode))
    }

    /// Match a request path, distinguishing "no such path" (404) from "wrong
    /// method for an existing path" (405).
    public func match(method: HTTPMethod, path: String) -> RouteMatch {
        // Decode the request's segments ONCE — they are the same for every route, and
        // decoding inside `captures` would redo it per route (R routes × S segments
        // allocations per request).
        var segments = Router.split(path)
        for i in 0..<segments.count { segments[i] = percentDecodePath(segments[i]) }
        var pathMatchedSomeRoute = false
        var best: (handler: Responder, params: Parameters, bodyMode: RequestBodyMode, score: Int)?

        for route in routes {
            guard let params = Router.captures(pattern: route.pattern, segments: segments) else {
                continue
            }
            pathMatchedSomeRoute = true
            guard route.method == method else { continue }
            // Prefer the most specific match: a literal beats `:param` beats a wildcard,
            // so `/users/new` wins over `/users/:id` regardless of registration order.
            // Ties keep the first registered (strict `<`).
            let score = specificity(route.pattern)
            if best == nil || score < best!.score {
                best = (route.handler, params, route.bodyMode, score)
            }
        }

        if let best { return .found(best.handler, best.params, best.bodyMode) }
        return pathMatchedSomeRoute ? .methodNotAllowed : .notFound
    }

    /// How specific a pattern is — lower is more specific. Wildcards dominate, then
    /// the count of `:param` segments; an all-literal route scores 0.
    private func specificity(_ pattern: [PathSegment]) -> Int {
        var score = 0
        for segment in pattern {
            switch segment {
            case .literal: break
            case .parameter: score += 1
            case .wildcard: score += 1000
            }
        }
        return score
    }

    // MARK: - Pattern parsing & matching

    private static let slash: UInt8 = 0x2F      // '/'
    private static let colon: UInt8 = 0x3A      // ':'
    private static let asterisk: UInt8 = 0x2A   // '*'

    /// Parse a path pattern string into segments.
    static func parse(_ path: String) -> [PathSegment] {
        var out: [PathSegment] = []
        for segment in split(path) {
            if segment.first == colon {
                out.append(.parameter(decodeUTF8(Array(segment.dropFirst()))))
            } else if segment.first == asterisk {
                let body = Array(segment.dropFirst())
                if body.first == asterisk {   // `**name` — zero or more
                    out.append(.wildcard(decodeUTF8(Array(body.dropFirst())), allowEmpty: true))
                } else {                       // `*name` — one or more
                    out.append(.wildcard(decodeUTF8(body), allowEmpty: false))
                }
            } else {
                // Store the literal DECODED, so it compares equal to the (also decoded)
                // request segment in `captures` — a route registered with a percent-escape
                // (`/a%20b`) stays reachable, and the decode happens once here, not per match.
                out.append(.literal(percentDecodePath(segment)))
            }
        }
        return out
    }

    /// Split a path into its non-empty UTF-8 segments.
    static func split(_ path: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in path.utf8 {
            if byte == slash {
                if !current.isEmpty { out.append(current); current.removeAll(keepingCapacity: true) }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// If `pattern` matches `segments` (the request path split and percent-DECODED —
    /// `match` does that once for all routes), return the captured parameters; else nil.
    /// Comparing decoded means a percent-encoded spelling of a literal path
    /// (`/admin/s%65ttings`) matches its route instead of silently falling through to
    /// a `:param` route (a handler/auth mismatch); segment splitting happens before
    /// decoding, so an encoded `%2F` still can't span segments.
    static func captures(pattern: [PathSegment], segments: [[UInt8]]) -> Parameters? {
        var params = Parameters()
        for i in 0..<pattern.count {
            switch pattern[i] {
            case .wildcard(let name, let allowEmpty):
                // Catch-all: must be last. `*` needs ≥1 remaining segment; `**` allows zero.
                guard i == pattern.count - 1, segments.count > i || allowEmpty else { return nil }
                var rest: [UInt8] = []
                for j in i..<segments.count {
                    if j > i { rest.append(slash) }
                    rest.append(contentsOf: segments[j])
                }
                params.set(name, decodeUTF8(rest))
                return params
            case .literal(let lit):
                guard i < segments.count, lit == segments[i] else { return nil }
            case .parameter(let name):
                guard i < segments.count else { return nil }
                params.set(name, decodeUTF8(segments[i]))
            }
        }
        // No catch-all consumed the tail → lengths must match exactly.
        return pattern.count == segments.count ? params : nil
    }
}
