import _Concurrency

// Identity resolution: `currentUser` resolves IDENTICALLY from a bearer token
// (native/API) or a signed cookie session (browser). One session mechanism
// (SessionManager), two transports. Header parsing is byte-wise so it links and
// runs in the embedded guest.

// MARK: - Extraction (byte-wise)

/// `Authorization: Bearer <token>` (scheme case-insensitive per RFC 6750).
public func extractBearerToken(_ request: Request) -> String? {
    guard let header = request.headers.first("authorization") else { return nil }
    let bytes = Array(header.utf8)
    let prefix = Array("bearer ".utf8)
    guard bytes.count > prefix.count else { return nil }
    for i in 0..<prefix.count {
        let c = (bytes[i] >= 65 && bytes[i] <= 90) ? bytes[i] + 32 : bytes[i]   // ASCII fold
        if c != prefix[i] { return nil }
    }
    return decodeUTF8(Array(bytes[prefix.count...]))
}

/// The value of cookie `name` from the `Cookie` header, or nil.
public func extractCookie(_ request: Request, name: String) -> String? {
    guard let header = request.headers.first("cookie") else { return nil }
    let nameBytes = Array(name.utf8)
    for rawPair in splitOnByte(Array(header.utf8), 0x3B) {   // ';'
        var pair = rawPair
        while pair.first == 0x20 { pair.removeFirst() }      // trim leading spaces
        guard let eq = pair.firstIndex(of: 0x3D) else { continue }   // '='
        if Array(pair[0..<eq]) == nameBytes { return decodeUTF8(Array(pair[(eq + 1)...])) }
    }
    return nil
}

// MARK: - Middleware + currentUser

/// Resolve identity from a bearer token OR a cookie session (bearer first, for
/// native/API), and attach it to the request. Unauthenticated requests pass through
/// with `principal == nil` (authorization, not authentication, decides access).
public func identityMiddleware(_ manager: SessionManager, cookieName: String = SessionCookie.name) -> MiddlewareFunction {
    { request, next in
        var req = request
        if let token = extractBearerToken(request) ?? extractCookie(request, name: cookieName) {
            req.principal = await manager.resolve(token)
        }
        return try await next(req)
    }
}

/// The installable form: builds the `SessionManager` from the REQUEST's bindings
/// (the signing secret named `secretName` via the secrets provider, sessions in
/// KV), mirroring `csrfProtection(secretName:)` — so `buildApp()` can wire it with
/// no per-request plumbing:
///
///     app.use(identityMiddleware())
///
/// Requests pass through unauthenticated when the secret or KV isn't configured
/// (identity resolution is optional; guarded routes still 401/redirect).
public func identityMiddleware(secretName: String = "AUTH_SECRET",
                               cookieName: String = SessionCookie.name) -> MiddlewareFunction {
    { request, next in
        var req = request
        if let token = extractBearerToken(request) ?? extractCookie(request, name: cookieName),
           let kv = request.context.kv {
            // A secrets-backend FAILURE (not merely an unconfigured secret) must be
            // visible — it logs everyone out for the duration, and a silent nil here
            // would read as a session bug.
            var key: [UInt8]? = nil
            do {
                key = try await request.context.secrets?.secret(secretName)
            } catch {
                // (`any Error` can't be stringified under Embedded — the guest logs
                // without the underlying reason.)
                #if hasFeature(Embedded)
                request.context.log("identityMiddleware: reading \(secretName) failed — treating the request as unauthenticated")
                #else
                request.context.log("identityMiddleware: reading \(secretName) failed: \(error) — treating the request as unauthenticated")
                #endif
            }
            if let key, !key.isEmpty {
                let manager = SessionManager(key: key, store: KVSessionStore(kv),
                                             now: { Int(PlatformClock.now() / 1000) })
                req.principal = await manager.resolve(token)
            }
        }
        return try await next(req)
    }
}

extension Request {
    /// The authenticated user id, or nil. Resolves identically from cookie or token.
    public var currentUser: String? { principal?.subject }
    public var isAuthenticated: Bool { principal != nil }
}

/// Middleware that blocks unauthenticated requests — drop it on a route group to put
/// everything behind it behind a login:
///
///     app.group("/admin", middleware: [requireAuth()]) { admin in … }
///
/// Needs `identityMiddleware` earlier in the chain (it resolves the principal). A
/// browser request is redirected to `login`; a request carrying a bearer token is an
/// API client, so it gets a 401 it can act on rather than a redirect it can't follow.
public func requireAuth(redirectTo login: String = "/login") -> MiddlewareFunction {
    { request, next in
        if request.isAuthenticated { return try await next(request) }
        return extractBearerToken(request) != nil ? .status(401) : .redirect(to: login)
    }
}

// MARK: - Transports (one protocol, two adapters)

/// How a session token is carried to/from a client. Swap the transport without
/// touching the session mechanism or authentication.
public protocol SessionTransport: Sendable {
    func extract(from request: Request) -> String?
    func attach(_ token: String, maxAge: Int, to response: Response) -> Response
    func clear(from response: Response) -> Response
}

/// Browser transport: a signed, HTTP-only, Secure, SameSite cookie (secure by
/// default; CSRF is wired separately via `csrfProtection`).
public struct CookieTransport: SessionTransport {
    public let name: String
    public let secure: Bool
    public let sameSite: String
    public init(name: String = SessionCookie.name, secure: Bool = true, sameSite: String = "Lax") {
        self.name = name; self.secure = secure; self.sameSite = sameSite
    }
    public func extract(from request: Request) -> String? { extractCookie(request, name: name) }
    public func attach(_ token: String, maxAge: Int, to response: Response) -> Response {
        response.settingCookie(SessionCookie.set(token, name: name, maxAge: maxAge, secure: secure, sameSite: sameSite))
    }
    public func clear(from response: Response) -> Response {
        response.settingCookie(SessionCookie.clear(name: name))
    }
}

/// Native/API transport: the token rides the `Authorization: Bearer` header; the
/// client stores it from the login response body, so attach/clear are no-ops.
public struct BearerTransport: SessionTransport {
    public init() {}
    public func extract(from request: Request) -> String? { extractBearerToken(request) }
    public func attach(_ token: String, maxAge: Int, to response: Response) -> Response { response }
    public func clear(from response: Response) -> Response { response }
}

// MARK: - Cookie building (HttpOnly/Secure/SameSite by default)

public enum SessionCookie {
    public static let name = "plumekit_session"
    public static func set(_ token: String, name: String = name, maxAge: Int,
                           secure: Bool = true, sameSite: String = "Lax") -> String {
        var cookie = name + "=" + token + "; HttpOnly; Path=/; SameSite=" + sameSite + "; Max-Age=" + String(maxAge)
        if secure { cookie += "; Secure" }
        return cookie
    }
    public static func clear(name: String = name) -> String {
        name + "=; HttpOnly; Path=/; Max-Age=0"
    }
}

extension Response {
    /// Append a `Set-Cookie` header (multiple cookies allowed).
    public func settingCookie(_ value: String) -> Response {
        var response = self
        response.headers.add("set-cookie", value)
        return response
    }
}
