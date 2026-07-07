import Foundation

// `plumekit generate auth` — a complete email + password auth scaffold: a User model +
// users table, and register / login / logout / forgot-password / reset flows with
// controllers and views. Identity resolves identically for browser sessions (a signed
// cookie) and API clients (a bearer token), so the same routes serve both. Built on the
// framework's auth primitives (PasswordAuthenticator, SessionManager, identityMiddleware).
// Requires the `kv` and `database` capabilities.
func generateAuth() -> Int32 {
    let files: [(path: String, label: String, contents: String)] = [
        ("Sources/App/Models/User.swift", "model", userModel),
        ("Sources/App/Models/PasswordReset.swift", "model", passwordResetModel),
        ("Sources/App/Models/EmailVerification.swift", "model", emailVerificationModel),
        ("Sources/App/Controllers/Auth.swift", "auth", authSource),
        ("Views/Auth/RegisterPage.plume", "view", registerView),
        ("Views/Auth/LoginPage.plume", "view", loginView),
        ("Views/Auth/ForgotPage.plume", "view", forgotView),
        ("Views/Auth/ResetPage.plume", "view", resetView),
        ("Views/Emails/VerifyEmail.plume", "view", verifyEmailView),
        ("Views/Emails/ResetEmail.plume", "view", resetEmailView),
    ]
    for file in files {
        if writeGenerated(file.contents, to: file.path, label: file.label) != 0 { return 1 }
    }

    // The auth schema as one auto-discovered migration file (frozen SQL; UNIQUE and
    // DEFAULT aren't in the schema builder, so it's spelled out here).
    let stamp = migrationTimestamp()
    let authMigration = #"""
    import PlumeORM

    // Built via the schema DSL so the id renders per-dialect (SQLite INTEGER PRIMARY KEY
    // / Postgres BIGSERIAL) — a frozen `INTEGER PRIMARY KEY` isn't auto-generated on
    // Postgres, so INSERT … RETURNING id would fail there.
    let createAuthTables = Migration(
        version: "\#(stamp)_create_auth_tables",
        up: { db in
            try await db.createTable("users") { t in
                t.id(); t.text("email"); t.text("password_hash"); t.integer("verified_at")
            }
            try await db.createTable("password_resets") { t in
                t.id(); t.text("email"); t.text("token"); t.integer("expires_at")
            }
            try await db.createTable("email_verifications") { t in
                t.id(); t.text("email"); t.text("token"); t.integer("expires_at")
            }
            _ = try await db.query("CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)", [])
        },
        down: { db in
            _ = try await db.query("DROP TABLE IF EXISTS email_verifications", [])
            _ = try await db.query("DROP TABLE IF EXISTS password_resets", [])
            _ = try await db.query("DROP TABLE IF EXISTS users", [])
        }
    )

    """#
    if writeGenerated(authMigration, to: "Sources/App/Database/Migrations/\(stamp)_CreateAuthTables.swift", label: "migration") != 0 { return 1 }

    print("")
    print("  Auth scaffold generated. To finish wiring it up:")
    print("")
    print("  1. Enable the `kv` and `database` capabilities in plumekit.toml.")
    print("  2. Call installAuth(app) in buildApp() (registers the identity middleware + routes).")
    print("  3. Set AUTH_SECRET (wrangler secret put AUTH_SECRET, or your env) before deploying.")
    print("  4. Run `plumekit migrate` — the migration is picked up automatically.")
    print("")
    print("  Routes: GET/POST /register, /login, /logout, /forgot,")
    print("  /reset, plus GET /verify and POST /verify/resend (email verification — sent as a")
    print("  Plume-view email via the mailer, or logged in local dev).")
    print("  In a handler, `request.currentUser` is the user id and `request.isAuthenticated` the")
    print("  flag; gate verified-only routes with `if let blocked = try await requireVerified(request)`.")
    return 0
}

private let userModel = #"""
import PlumeORM

// The application user. Credentials (email + password hash) live here, so the `users`
// table is the single source of truth for authentication. Add profile fields as needed.
@Model
final class User: Model {
    var id: Int
    var email: String
    var passwordHash: String
    var verifiedAt = 0   // epoch seconds; 0 = email not verified yet
}
"""#

private let emailVerificationModel = #"""
import PlumeORM

// A one-time email-verification token. Registration creates one and emails the link;
// GET /verify consumes it and stamps `User.verifiedAt`.
@Model
final class EmailVerification: Model {
    var id: Int
    var email: String
    var token: String
    var expiresAt: Int
}
"""#

private let passwordResetModel = #"""
import PlumeORM

// A one-time password-reset token. `forgot` creates one; `reset` consumes it.
@Model
final class PasswordReset: Model {
    var id: Int
    var email: String
    var token: String
    var expiresAt: Int
}
"""#

private let authSource = #"""
import PlumeCore
import PlumeORM
import PlumeRuntime

// Email + password auth, backed by the `users` table. Identity resolves the same way
// for browser sessions (a signed cookie) and API clients (a bearer token). Requires the
// `kv` and `database` capabilities.

// The session signing key comes from the AUTH_SECRET secret (wrangler secret / env),
// never a literal in the source. In development, if it's unset, a fixed dev key is
// used so `plumekit dev` works out of the box; production must set a real one.
let devAuthKey = "dev-only-auth-key-not-for-production"

func authSigningKey() async -> [UInt8] {
    if let secret = try? await Secrets.current.secretString("AUTH_SECRET"), !secret.isEmpty {
        return Array(secret.utf8)
    }
    return Array(devAuthKey.utf8)
}

// Credentials read/write the `users` table, keeping `User` the source of truth. The
// queries use the request's database automatically — no `in:` needed inside a handler.
struct UserStore: CredentialStore {
    func ensureTable() async throws {}   // the `users` table is created by your migration
    func findCredential(email: String) async throws -> (subject: String, passwordHash: String)? {
        guard let user = try await User.where(User.email == email).all().first else { return nil }
        return (String(user.id), user.passwordHash)
    }
    func createCredential(email: String, passwordHash: String) async throws -> String {
        let user = User(email: email, passwordHash: passwordHash)
        _ = try await user.save()
        return String(user.id)
    }
}

func makeAuthenticator() -> PasswordAuthenticator {
    PasswordAuthenticator(hasher: BcryptHasher(), store: UserStore())
}

func makeSessions() async -> SessionManager {
    SessionManager(
        key: await authSigningKey(),
        store: KVSessionStore(KV.current),
        now: { Int(ORMClock.now() / 1000) }
    )
}

// Register the identity middleware + auth routes. Call installAuth(app) in buildApp().
func installAuth(_ app: Application) {
    app.use { request, next in
        var req = request
        if let token = extractBearerToken(request) ?? extractCookie(request, name: SessionCookie.name) {
            req.principal = await (await makeSessions()).resolve(token)
        }
        return try await next(req)
    }
    let auth = AuthController()
    app.get("/register") { try await auth.showRegister($0) }
    app.post("/register") { try await auth.register($0) }
    app.get("/login") { try await auth.showLogin($0) }
    app.post("/login") { try await auth.login($0) }
    app.post("/logout") { try await auth.logout($0) }
    app.get("/forgot") { try await auth.showForgot($0) }
    app.post("/forgot") { try await auth.forgot($0) }
    app.get("/reset") { try await auth.showReset($0) }
    app.post("/reset") { try await auth.reset($0) }
    app.get("/verify") { try await auth.verify($0) }
    app.post("/verify/resend") { try await auth.resendVerification($0) }
}

/// Guard for routes that need a *verified* account:
///
///     if let blocked = try await requireVerified(request) { return blocked }
///
func requireVerified(_ request: Request) async throws -> Response? {
    guard let subject = request.currentUser, let id = Int(subject),
          let user = try await User.find(id), user.verifiedAt > 0 else {
        return .text("Please verify your email first", status: 403)
    }
    return nil
}

struct AuthController {
    func showRegister(_ request: Request) async throws -> Response {
        .view(registerPage())
    }
    func showLogin(_ request: Request) async throws -> Response {
        .view(loginPage())
    }
    func showForgot(_ request: Request) async throws -> Response {
        .view(forgotPage())
    }
    func showReset(_ request: Request) async throws -> Response {
        .view(resetPage(token: request.queryParams["token"] ?? ""))
    }

    func register(_ request: Request) async throws -> Response {
        let email = field(request, "email"), password = field(request, "password")
        switch try await makeAuthenticator().register(email: email, password: password) {
        case .emailTaken: return fail(request, "Email already registered", 409)
        case .created(let subject):
            try await sendVerificationEmail(email, request: request)
            return succeed(request, token: await makeSessions().issue(subject: subject))
        }
    }

    func verify(_ request: Request) async throws -> Response {
        let token = request.queryParams["token"] ?? ""
        guard let verification = try await EmailVerification.where(EmailVerification.token == token).all().first,
              verification.expiresAt > Int(ORMClock.now() / 1000) else {
            return fail(request, "Invalid or expired verification link", 400)
        }
        guard let user = try await User.where(User.email == verification.email).all().first else {
            return fail(request, "No such account", 404)
        }
        user.verifiedAt = Int(ORMClock.now() / 1000)
        _ = try await user.save()
        try await verification.delete()
        if request.wantsJSON { return .json("{\"ok\":true}") }
        return .redirect(to: "/").flash("Email verified — you're all set")
    }

    func resendVerification(_ request: Request) async throws -> Response {
        let email = field(request, "email")
        if try await User.where(User.email == email).all().first != nil {
            try await sendVerificationEmail(email, request: request)
        }
        if request.wantsJSON { return .json("{\"ok\":true}") }
        return .text("If that account exists, a verification link was sent. (Dev: see the logs.)")
    }

    func login(_ request: Request) async throws -> Response {
        let email = field(request, "email"), password = field(request, "password")
        guard let subject = try await makeAuthenticator().authenticate(email: email, password: password) else {
            return fail(request, "Invalid email or password", 401)
        }
        return succeed(request, token: await makeSessions().issue(subject: subject))
    }

    func logout(_ request: Request) async throws -> Response {
        if let token = extractBearerToken(request) ?? extractCookie(request, name: SessionCookie.name) {
            await (await makeSessions()).revoke(token)
        }
        if request.wantsJSON { return .json("{\"ok\":true}") }
        return CookieTransport().clear(from: .redirect(to: "/login"))
    }

    func forgot(_ request: Request) async throws -> Response {
        let email = field(request, "email")
        let reset = PasswordReset(email: email, token: SessionManager.randomToken(), expiresAt: Int(ORMClock.now() / 1000) + 3600)
        _ = try await reset.save()
        let link = "/reset?token=\(reset.token)"
        if let mailer = request.context.mailer {
            try await mailer.send(from: "no-reply@example.com", to: email,
                                  subject: "Reset your password",
                                  view: resetEmail(link: link),
                                  text: "Reset your password: \(link)")
        } else {
            request.context.log("Password reset for \(email): \(link)")
        }
        if request.wantsJSON { return .json("{\"ok\":true}") }
        return .text("If that account exists, a reset link was sent. (Dev: see the logs.)")
    }

    func reset(_ request: Request) async throws -> Response {
        let posted = field(request, "token")
        let token = posted.isEmpty ? (request.queryParams["token"] ?? "") : posted
        guard let reset = try await PasswordReset.where(PasswordReset.token == token).all().first,
              reset.expiresAt > Int(ORMClock.now() / 1000) else {
            return fail(request, "Invalid or expired reset token", 400)
        }
        guard let user = try await User.where(User.email == reset.email).all().first else {
            return fail(request, "No such account", 404)
        }
        let newPassword = field(request, "password")
        guard !newPassword.isEmpty else {
            return fail(request, "Password cannot be empty", 400)
        }
        user.passwordHash = BcryptHasher().hash(newPassword)
        _ = try await user.save()
        try await reset.delete()
        if request.wantsJSON { return .json("{\"ok\":true}") }
        return .redirect(to: "/login")
    }

    // MARK: helpers (dual web/JSON)

    /// Create a fresh verification token and email the link — an HTML body rendered
    /// from Views/Emails/VerifyEmail.plume with a plain-text fallback. Without a mailer
    /// binding (local dev), the link is logged instead.
    private func sendVerificationEmail(_ email: String, request: Request) async throws {
        let verification = EmailVerification(email: email, token: SessionManager.randomToken(),
                                             expiresAt: Int(ORMClock.now() / 1000) + 86_400)
        _ = try await verification.save()
        let link = "/verify?token=\(verification.token)"
        if let mailer = request.context.mailer {
            try await mailer.send(from: "no-reply@example.com", to: email,
                                  subject: "Verify your email",
                                  view: verifyEmail(link: link),
                                  text: "Confirm your account: \(link)")
        } else {
            request.context.log("Email verification for \(email): \(link)")
        }
    }

    private func field(_ request: Request, _ name: String) -> String {
        if request.hasJSONBody, case .string(let value)? = request.json()?[name] { return value }
        return request.form[name] ?? ""
    }
    private func succeed(_ request: Request, token: String) -> Response {
        if request.wantsJSON { return .json("{\"token\":\"\(token)\"}") }
        return CookieTransport().attach(token, maxAge: 60 * 60 * 24 * 7, to: .redirect(to: "/"))
    }
    private func fail(_ request: Request, _ message: String, _ status: Int) -> Response {
        request.wantsJSON ? .json("{\"error\":\"\(message)\"}", status: status) : .text(message, status: status)
    }
}
"""#

private let registerView = #"""
@component RegisterPage() {@Layout(title: "Register") {
  <h1>Register</h1>
  <form method="post" action="/register">
    @csrf
    <input name="email" type="email" placeholder="Email">
    <input name="password" type="password" placeholder="Password">
    <button type="submit">Create account</button>
  </form>
  <p>Already have an account? <a href="/login">Log in</a></p>
}}
"""#

private let loginView = #"""
@component LoginPage() {@Layout(title: "Log in") {
  <h1>Log in</h1>
  <form method="post" action="/login">
    @csrf
    <input name="email" type="email" placeholder="Email">
    <input name="password" type="password" placeholder="Password">
    <button type="submit">Log in</button>
  </form>
  <p><a href="/register">Register</a> · <a href="/forgot">Forgot your password?</a></p>
}}
"""#

private let forgotView = #"""
@component ForgotPage() {@Layout(title: "Forgot password") {
  <h1>Forgot your password?</h1>
  <form method="post" action="/forgot">
    @csrf
    <input name="email" type="email" placeholder="Email">
    <button type="submit">Send reset link</button>
  </form>
}}
"""#

private let resetView = #"""
@component ResetPage(token: String) {@Layout(title: "Reset password") {
  <h1>Reset password</h1>
  <form method="post" action="/reset">
    @csrf
    <input type="hidden" name="token" value="{token}">
    <input name="password" type="password" placeholder="New password">
    <button type="submit">Reset password</button>
  </form>
}}
"""#

private let verifyEmailView = #"""
@component VerifyEmail(link: String) {<!doctype html>
<html>
  <body style="font-family: system-ui, sans-serif; color: #1a1a1a; padding: 24px;">
    <h1 style="font-size: 20px;">Confirm your email</h1>
    <p>Tap the button below to verify your address and finish setting up your account.</p>
    <p><a href="{link}" style="display: inline-block; background: #2563eb; color: #fff; padding: 10px 18px; border-radius: 8px; text-decoration: none;">Verify email</a></p>
    <p style="color: #666; font-size: 13px;">If you didn't create an account, you can ignore this email. The link expires in 24 hours.</p>
  </body>
</html>}
"""#

private let resetEmailView = #"""
@component ResetEmail(link: String) {<!doctype html>
<html>
  <body style="font-family: system-ui, sans-serif; color: #1a1a1a; padding: 24px;">
    <h1 style="font-size: 20px;">Reset your password</h1>
    <p>Tap the button below to choose a new password. This link works once.</p>
    <p><a href="{link}" style="display: inline-block; background: #2563eb; color: #fff; padding: 10px 18px; border-radius: 8px; text-decoration: none;">Reset password</a></p>
    <p style="color: #666; font-size: 13px;">If you didn't ask to reset your password, you can ignore this email. The link expires in one hour.</p>
  </body>
</html>}
"""#
