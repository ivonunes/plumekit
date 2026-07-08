# Auth

Batteries included, removable. Three separate layers behind protocols; conflating
them is what makes auth rigid. Secure by default; the dangerous option requires a
conscious opt-out. Works on every target, including the Cloudflare Wasm build.

## The three layers

| Layer | What | Default | Swap without touching… |
|---|---|---|---|
| Authentication | proving who you are | `PasswordAuthenticator` (PBKDF2) | sessions, policies |
| Session/Identity | carrying identity across requests | `SessionManager` + cookie/bearer | authentication, policies |
| Authorisation | what you may do | `Policy` mechanism (no model) | authentication, sessions |

The layers don't reference each other's types, so each swaps independently: a
non-password method flows through the same session machinery, and the same
authenticator works across two different session stores.

## Identity: `currentUser` from cookie or bearer

`request.currentUser` (the subject id) resolves identically from a signed cookie
session (browser) or an `Authorization: Bearer` token (native/API), never
cookie-only. One mechanism, two transports:

- **Session token**: HMAC-signed `subject|jti|expiry` (secret via the SecretProvider).
  The secret never crosses the wire; the client treats the token as opaque.
- **Revocation**: a denylist in a `SessionStore` (default `KVSessionStore`), checked
  on resolve. Logout revokes the jti. Stateless happy path; revocation needs only
  KV get+put.
- **CookieTransport**: `HttpOnly; Secure; SameSite=Lax` by default; CSRF auto-wired.
  **BearerTransport**: the `Authorization` header (CSRF-exempt: a browser
  never auto-sends it).

## Authentication: email + password, secure by default

`PasswordAuthenticator` over a `CredentialStore` (default `SQLCredentialStore`,
dialect-aware). Hashing is `PasswordHasher`, default **PBKDF2-HMAC-SHA256** (600k
iterations, per OWASP guidance).
Plaintext is never stored or returned; verify is timing-safe; an unknown-email login
still runs one hash (no user-enumeration timing leak). `register` returns
`.created(subject)` / `.emailTaken` as a value rather than throwing. Argon2id/bcrypt
are the documented production swap (a native `PasswordHasher`).

## Authorisation: a place and a shape, not a model

`Policy` ships the mechanism; the app owns the rules (no RBAC/ownership/tenant baked
in):

```swift
struct AccountPolicy: Policy {
    func can(_ p: Principal?, _ action: Action, on id: String) -> Bool {
        action == .view ? p != nil : (p?.is(id) ?? false)   // ownership
    }
}
// handler (fail closed): if let denied = request.authorize(AccountPolicy(), .edit, on: id) { return denied }
// view fragment:        if request.allows(AccountPolicy(), .edit, on: id) { … }
```

`requireAuthenticated()` → 401, `authorize(...)` → 403, both fail-closed.

## Protecting a route group

To put a whole section behind a login, add `requireAuth()` as group middleware, with
no per-handler check needed:

```swift
app.group("/admin", middleware: [requireAuth()]) { admin in
    admin.get("/") { _ in .view(Dashboard()) }   // only reached when authenticated
}
```

It needs `identityMiddleware` earlier in the chain (that resolves the principal). A
browser request is redirected to `/login` (pass `requireAuth(redirectTo:)` to change
it); a request carrying a bearer token gets a `401` instead of a redirect it can't
follow. For finer control inside a handler, use `request.isAuthenticated` /
`requireAuthenticated()` directly.

## Email verification (scaffolded)

`plumekit generate auth` layers email verification on top: registration creates an
`EmailVerification` token and emails the link as a **Plume-view email**
(`Views/Emails/VerifyEmail.plume`, rendered through the scaffold's
`Mailer.send(view:text:)` helper; without a mailer binding the link is logged, so
dev keeps working). `GET /verify?token=…` stamps `User.verifiedAt` (one-time, 24 h
expiry, flash confirmation); `POST /verify/resend` re-sends. Gate verified-only
routes fail-closed:

```swift
if let blocked = try await requireVerified(request) { return blocked }
```

The users table gains `verified_at INTEGER NOT NULL DEFAULT 0`, and the auth views
live in `Views/Auth/`. See [Generators](generators.md#auth) for the full scaffold.


## Other authentication methods

Password authentication ships by default. Other methods (OAuth, magic links,
passkeys/WebAuthn, 2FA) plug into the same `Authentication` layer: implement the
credential check and issue a session the same way the password flow does.
