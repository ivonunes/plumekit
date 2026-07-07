import Testing
@testable import PlumeCore

private actor MemSessionStore: SessionStore {
    var revoked: Set<String> = []
    func isRevoked(_ id: String) -> Bool { revoked.contains(id) }
    func revoke(_ id: String, until: Int) { revoked.insert(id) }
}

private final class ClockBox: @unchecked Sendable { var t: Int; init(_ t: Int) { self.t = t } }

private func resolvedUser(_ mw: MiddlewareFunction, _ request: Request) async throws -> String {
    let response = try await mw(request) { req in .text(req.currentUser ?? "nil") }
    return decodeUTF8(response.body)
}

@Test func currentUserResolvesFromBearerAndCookieIdentically() async throws {
    let manager = SessionManager(key: Array("k".utf8), store: MemSessionStore(),
                                 ttlSeconds: 3600, now: { 1_000_000 })
    let token = manager.issue(subject: "user-1")
    let mw = identityMiddleware(manager)

    var bearer = Request(method: .get, path: "/")
    bearer.headers.add("authorization", "Bearer " + token)
    #expect(try await resolvedUser(mw, bearer) == "user-1")

    var cookie = Request(method: .get, path: "/")
    cookie.headers.add("cookie", "other=x; \(SessionCookie.name)=\(token); more=y")
    #expect(try await resolvedUser(mw, cookie) == "user-1")        // identical resolution

    #expect(try await resolvedUser(mw, Request(method: .get, path: "/")) == "nil")  // no creds
}

@Test func forgedExpiredAndRevokedAreRejected() async throws {
    let store = MemSessionStore()
    let clock = ClockBox(1_000_000)
    let manager = SessionManager(key: Array("k".utf8), store: store, ttlSeconds: 100, now: { clock.t })
    let mw = identityMiddleware(manager)
    func bearer(_ t: String) -> Request {
        var r = Request(method: .get, path: "/"); r.headers.add("authorization", "Bearer " + t); return r
    }

    let token = manager.issue(subject: "user-1")
    #expect(try await resolvedUser(mw, bearer(token)) == "user-1")          // valid

    #expect(try await resolvedUser(mw, bearer(token + "ff")) == "nil")       // forged signature
    #expect(try await resolvedUser(mw, bearer("garbage")) == "nil")          // malformed

    await manager.revoke(token)
    #expect(try await resolvedUser(mw, bearer(token)) == "nil")              // revoked

    let fresh = manager.issue(subject: "user-2")
    clock.t += 1000                                                          // past expiry (ttl 100)
    #expect(try await resolvedUser(mw, bearer(fresh)) == "nil")             // expired
}

@Test func cookieTransportSetsSecureHttpOnlyCookie() {
    let transport = CookieTransport()
    let response = transport.attach("tok", maxAge: 3600, to: .text("ok"))
    let setCookie = response.headers.first("set-cookie") ?? ""
    #expect(setCookie.contains("plumekit_session=tok"))
    #expect(setCookie.contains("HttpOnly"))
    #expect(setCookie.contains("Secure"))
    #expect(setCookie.contains("SameSite=Lax"))
}

@Test func requireAuthBlocksAnonymousAndAllowsAuthenticated() async throws {
    let manager = SessionManager(key: Array("k".utf8), store: MemSessionStore(),
                                 ttlSeconds: 3600, now: { 1_000_000 })
    let token = manager.issue(subject: "user-1")
    let identity = identityMiddleware(manager)
    let guardMW = requireAuth()
    func run(_ req: Request) async throws -> Response {
        try await identity(req) { r1 in try await guardMW(r1) { _ in .text("ok") } }
    }

    var authed = Request(method: .get, path: "/admin")
    authed.headers.add("cookie", "\(SessionCookie.name)=\(token)")
    #expect(try await run(authed).status == 200)                 // authenticated → through

    let anon = Request(method: .get, path: "/admin")
    #expect(try await run(anon).status == 303)                   // anonymous browser → redirect

    var api = Request(method: .get, path: "/admin")
    api.headers.add("authorization", "Bearer not-a-valid-token")
    #expect(try await run(api).status == 401)                    // API client → 401, not a redirect
}
