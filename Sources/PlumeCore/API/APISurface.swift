import _Concurrency

// The dedicated, opt-in API surface — a versioned namespace with its own
// middleware (bearer-token auth, rate limiting), structured error envelopes,
// pagination, and allow-list serialization. SEPARATE from web routes; it does not
// change how content-negotiated endpoints behave. Apps opt in by mounting
// routes under the API prefix and adding the API middleware.

/// A machine-readable error envelope, content-typed JSON:
///   {"error":{"code":..,"message":..,"fields":[{"field":..,"message":..}]}}
/// Built via the reflection-free JSON codec — no reflective serializer.
public struct APIError: Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public let fields: [(field: String, message: String)]

    public init(status: Int, code: String, message: String,
                fields: [(field: String, message: String)] = []) {
        self.status = status; self.code = code; self.message = message; self.fields = fields
    }

    public func response() -> Response {
        let fieldsJSON = JSONValue.array(fields.map {
            .object([("field", .string($0.field)), ("message", .string($0.message))])
        })
        let envelope = JSONValue.object([("error", .object([
            ("code", .string(code)),
            ("message", .string(message)),
            ("fields", fieldsJSON),
        ]))])
        return Response.json(envelope, status: status)
    }
}

// MARK: - Serialization allow-list

/// A model's API JSON representation is an EXPLICIT allow-list the app declares —
/// never "encode the whole model". Built with the reflection-free JSON codec, so a
/// column the app doesn't list (a password hash, an internal flag) can't leak.
public protocol APIRepresentable {
    func apiJSON() -> JSONValue
}

// MARK: - Pagination envelope

/// Wrap allow-list-serialized items + pagination metadata in a consistent envelope:
///   {"data":[…],"pagination":{"limit":..,"offset":..,"hasMore":..}}
public func paginatedJSON(_ items: [JSONValue], limit: Int, offset: Int, hasMore: Bool) -> JSONValue {
    .object([
        ("data", .array(items)),
        ("pagination", .object([
            ("limit", .int(Int64(limit))),
            ("offset", .int(Int64(offset))),
            ("hasMore", .bool(hasMore)),
        ])),
    ])
}

// MARK: - Rate limiting (platform-neutral, KV-backed fixed window)

/// Fixed-window rate limit middleware over the KV capability. On `prefix` paths,
/// counts requests per principal (or anon) per window; returns a structured 429 past
/// `limit`. Platform-neutral; swap the counter by replacing this middleware.
public func rateLimit(
    prefix: String = "/api/",
    limit: Int,
    windowSeconds: Int = 60,
    now: @escaping @Sendable () -> Int
) -> MiddlewareFunction {
    { request, next in
        guard pathHasPrefix(request.path, prefix), let kv = request.context.kv else {
            return try await next(request)
        }
        let key = "plumekit:ratelimit:" + (request.currentUser ?? "anon")
        let count = await rateLimitHit(kv: kv, key: key, windowSeconds: windowSeconds, now: now())
        if count > limit {
            return APIError(status: 429, code: "rate_limited",
                            message: "too many requests").response()
        }
        return try await next(request)
    }
}

func rateLimitHit(kv: KV, key: String, windowSeconds: Int, now: Int) async -> Int {
    let window = now / max(1, windowSeconds)
    var count = 1
    if let bytes = await kv.get(key) {
        let parts = splitOnByte(bytes, 0x7C)   // '|'  →  "<window>|<count>"
        if parts.count == 2, let saved = Int(decodeUTF8(parts[0])), saved == window,
           let c = Int(decodeUTF8(parts[1])) {
            count = c + 1
        }
    }
    await kv.put(key, Array((String(window) + "|" + String(count)).utf8))
    return count
}

/// Byte-wise path prefix test (Embedded-safe; no Unicode tables needed).
public func pathHasPrefix(_ path: String, _ prefix: String) -> Bool {
    let p = Array(path.utf8), pre = Array(prefix.utf8)
    if p.count < pre.count { return false }
    for i in 0..<pre.count where p[i] != pre[i] { return false }
    return true
}

/// API token-auth middleware: on `prefix` paths, require a valid BEARER token —
/// cookie auth is NOT accepted on the API surface. The identity middleware must
/// run before this (it resolves the principal); this enforces that a bearer was
/// actually presented and resolved, and returns a structured 401 otherwise.
public func requireAPIToken(prefix: String = "/api/") -> MiddlewareFunction {
    { request, next in
        guard pathHasPrefix(request.path, prefix) else { return try await next(request) }
        guard extractBearerToken(request) != nil, request.isAuthenticated else {
            return APIError(status: 401, code: "unauthorized",
                            message: "a valid bearer token is required").response()
        }
        return try await next(request)
    }
}
