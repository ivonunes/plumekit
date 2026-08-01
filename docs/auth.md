# Auth

PlumeKit ships a complete auth stack: password login, signed sessions carried by a cookie or a bearer token, and typed authorisation policies. Batteries included, removable: each layer sits behind a protocol, so you can replace one without touching the others. The defaults are secure, and the dangerous option always requires a conscious opt-out. Everything works on every target, including the Cloudflare Worker.

## The three layers

Auth turns rigid when authentication, sessions and authorisation blur into one thing. PlumeKit keeps them as three separate layers:

| Layer | What | Default | Swap without touching… |
|---|---|---|---|
| Authentication | proving who you are | `PasswordAuthenticator` (PBKDF2) | sessions, policies |
| Session/Identity | carrying identity across requests | `SessionManager` + cookie/bearer | authentication, policies |
| Authorisation | what you may do | `Policy` mechanism (no model) | authentication, sessions |

The layers do not reference each other's types, so each one swaps independently. A non-password login method flows through the same session machinery, and the same authenticator works with two different session stores.

## Sessions and identity

Once a user has proved who they are, something has to carry that identity across requests. In PlumeKit that is `request.currentUser`: the authenticated subject id, or nil.

It resolves identically from a signed cookie session (a browser) or an `Authorization: Bearer` token (a native or API client), never cookie-only. One session mechanism, two transports.

### Session tokens

A session token is `subject|jti|expiry`, HMAC-signed with a secret from the SecretProvider. The secret never crosses the wire; the client treats the whole token as opaque.

### Revocation

The happy path is stateless: a token proves itself with its signature and expiry. Revocation is a denylist in a `SessionStore` (default `KVSessionStore`), checked when a token resolves. Logout revokes the token's jti. The whole scheme needs only KV get and put.

### Transports

Two transports carry the token, and both feed the same resolution:

- `CookieTransport` for browsers: `HttpOnly; Secure; SameSite=Lax` by default, with CSRF protection auto-wired.
- `BearerTransport` for native and API clients: the `Authorization` header. It is CSRF-exempt because a browser never auto-sends that header.

## Password authentication

`PasswordAuthenticator` is the built-in email and password method. Credentials live in a `CredentialStore` (default `SQLCredentialStore`, which is dialect-aware). `register` returns `.created(subject)` or `.emailTaken` as a value rather than throwing.

### Hashing

Passwords are hashed with a `PasswordHasher`. The default is **PBKDF2-HMAC-SHA256** at 600k iterations, per OWASP guidance. Plaintext is never stored or returned, and verification is timing-safe. A login attempt for an unknown email still runs one hash, so response timing does not reveal which emails exist.

### Swapping the hasher

`PasswordHasher` is a protocol, so a deployment can swap in Argon2id or bcrypt (the recommended production hashers) without touching sessions or authorisation. Two ready-made alternatives ship with the framework: `BcryptHasher` verifies and mints bcrypt hashes, for adopting an app whose stored hashes are already bcrypt, and `MigrationHasher` verifies existing bcrypt hashes while minting PBKDF2, so each password upgrades to the default the next time it is re-hashed (after a password reset, for example).

## Authorisation with policies

Authorisation in PlumeKit is a place and a shape, not a model. `Policy` ships the mechanism; the app owns the rules. No RBAC, ownership or tenant model is baked in; those are yours to express in `can`:

```swift
struct AccountPolicy: Policy {
    func can(_ p: Principal?, _ action: Action, on id: String) -> Bool {
        action == .view ? p != nil : (p?.is(id) ?? false)   // ownership
    }
}
```

Check a policy in a handler with `authorize`, which returns a 403 response when the policy denies, or nil to proceed:

```swift
if let denied = request.authorize(AccountPolicy(), .edit, on: id) { return denied }
```

To gate a view fragment, `allows` is the boolean form:

```swift
if request.allows(AccountPolicy(), .edit, on: id) { … }
```

`requireAuthenticated()` is the matching authentication gate: it returns a 401 response when nobody is signed in. Both gates fail closed.

## Protecting a route group

To put a whole section of the app behind a login, add `requireAuth()` as group middleware, with no per-handler check needed:

```swift
app.group("/admin", middleware: [requireAuth()]) { admin in
    admin.get("/") { _ in .view(Dashboard()) }   // only reached when authenticated
}
```

A browser request that is not signed in is redirected to `/login`; pass `requireAuth(redirectTo:)` to change the destination. A request carrying a bearer token gets a `401` instead of a redirect it can't follow.

### Wiring the identity middleware

`requireAuth()` needs `identityMiddleware` earlier in the chain; that is what resolves the principal. The installable form builds everything from the request's bindings, the signing key from the `AUTH_SECRET` secret and sessions in KV, so wiring it is one line in `buildApp()`:

```swift
app.use(identityMiddleware())          // AUTH_SECRET + KV; pass secretName: to rename
```

The `identityMiddleware(_ manager:)` overload takes a ready `SessionManager` when you build your own.

### Checks inside a handler

For finer control than group middleware, use `request.isAuthenticated` or `requireAuthenticated()` directly in the handler.

See [Middleware](middleware.md) for how the middleware chain runs.

## Email verification

`plumekit generate auth` layers email verification on top of the basic flow. Registration creates an `EmailVerification` token and emails the link as a Plume-view email (`Views/Emails/VerifyEmail.plume`, rendered through the scaffold's `Mailer.send(view:text:)` helper). Without a mailer binding the link is logged instead, so development keeps working.

`GET /verify?token=…` stamps `User.verifiedAt` and flashes a confirmation. The token is one-time and expires after 24 hours. `POST /verify/resend` re-sends the link.

Gate routes that need a verified account, fail-closed:

```swift
if let blocked = try await requireVerified(request) { return blocked }
```

`requireVerified` returns a 403 response for an unverified account, or nil to proceed.

The scaffold gives the users table a non-nullable integer `verified_at` column (0 until the email is verified) and puts the auth views in `Views/Auth/`. See [Generators](generators.md#auth) for the full scaffold.

## Other authentication methods

Password authentication is the only built-in method. Other methods (OAuth, magic links, passkeys/WebAuthn, 2FA) plug into the same `Authentication` layer: implement the credential check and issue a session the same way the password flow does.
