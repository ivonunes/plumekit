import PlumeCore
import PlumeORM   // ORMClock (platform clock)
import _Concurrency

// Auth wired into the example — the SAME code on native, Cloudflare, and AWS. The
// three layers stay separate: PasswordAuthenticator (method) over SQLCredentialStore,
// SessionManager (sessions) over KVSessionStore, and an app Policy (authorization).

func authNowSeconds() -> Int { Int(ORMClock.now() / 1000) }

// Read a credential field from a JSON body (API) or a urlencoded form (browser).
func authField(_ request: Request, _ name: String) -> String? {
    if request.hasJSONBody { return request.json()?[name]?.stringValue }
    return request.form[name]
}

// Demo cost (100k); production uses the 600k default. Built per request from bindings.
func exampleAuthenticator(_ request: Request) -> PasswordAuthenticator {
    PasswordAuthenticator(hasher: PBKDF2Hasher(iterations: 100_000),
                          store: SQLCredentialStore(request.bindings.database))
}

func exampleSessionManager(_ request: Request) async -> SessionManager? {
    guard let secrets = request.context.secrets,
          let key = try? await secrets.secret("AUTH_SECRET"), !key.isEmpty else {
        return nil
    }
    return SessionManager(key: key, store: KVSessionStore(request.bindings.kv), now: authNowSeconds)
}

// A sample policy: only the owner may edit their account (ownership via the subject).
struct AccountPolicy: Policy {
    enum Action { case view, edit }
    func can(_ principal: Principal?, _ action: Action, on accountID: String) -> Bool {
        switch action {
        case .view: return principal != nil
        case .edit: return principal?.is(accountID) ?? false
        }
    }
}

/// The auth routes (register/login/logout/me + a policy-gated route). Cookie for the
/// browser (HttpOnly/Secure/SameSite), bearer token for API/native (negotiated).
func registerAuthRoutes(_ app: Application) {
    app.post("/auth/register") { request in
        let auth = exampleAuthenticator(request)
        try await auth.ensureReady()
        guard let email = authField(request, "email"), let password = authField(request, "password") else {
            return .text("email + password required", status: 400)
        }
        switch try await auth.register(email: email, password: password) {
        case .emailTaken:
            return .text("email already registered", status: 409)
        case .created(let subject):
            return try await issueSession(request, subject: subject, message: "registered " + subject)
        }
    }

    app.post("/auth/login") { request in
        let auth = exampleAuthenticator(request)
        try await auth.ensureReady()
        guard let email = authField(request, "email"), let password = authField(request, "password") else {
            return .text("email + password required", status: 400)
        }
        guard let subject = try await auth.authenticate(email: email, password: password) else {
            return .text("invalid credentials", status: 401)
        }
        return try await issueSession(request, subject: subject, message: "logged in " + subject)
    }

    app.post("/auth/logout") { request in
        if let token = extractBearerToken(request) ?? extractCookie(request, name: SessionCookie.name),
           let manager = await exampleSessionManager(request) {
            await manager.revoke(token)
        }
        return CookieTransport().clear(from: .text("logged out"))
    }

    app.get("/auth/me") { request in
        .text(request.currentUser ?? "anonymous")
    }

    // Policy-gated handler (fails closed): only the owner may edit their account.
    app.get("/account/:id/edit") { request in
        let id = request.parameters["id"] ?? ""
        if let denied = request.authorize(AccountPolicy(), .edit, on: id) { return denied }
        return .text("editing account " + id)
    }
}

// Issue a session: bearer token in the JSON body for API clients, or an HttpOnly
// Secure SameSite cookie for browsers (content-negotiated).
private func issueSession(_ request: Request, subject: String, message: String) async throws -> Response {
    guard let manager = await exampleSessionManager(request) else {
        return .text("AUTH_SECRET not configured", status: 500)
    }
    let token = manager.issue(subject: subject)
    if request.wantsJSON {
        return .json("{\"subject\":\"" + subject + "\",\"token\":\"" + token + "\"}")
    }
    return CookieTransport().attach(token, maxAge: 3600, to: .text(message))
}
