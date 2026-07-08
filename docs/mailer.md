# Mailer

Transactional email is a portable capability, alongside the database, KV, object storage and
the rest. Your app builds an `EmailMessage` and hands it to the mailer binding; the
adapter configured for the target decides how it is actually delivered. The protocol
names no provider and no transport, so the same send runs unchanged on the native
server and the Cloudflare Worker.

## Enabling the capability

Declare the capability in `plumekit.toml` and pick a native driver:

```toml
[capabilities]
mailer = true

[targets.native]
mailer = "log"      # log | smtp
```

Declaring `mailer = true` generates a typed, non-optional `request.bindings.mailer`
accessor. (You can also read the optional `request.context.mailer` directly, e.g.
from code without the generated bindings.)

## Sending mail

```swift
app.post("/signup") { request in
    let mailer = request.bindings.mailer

    // Convenience: a plain-text message.
    try await mailer.send(
        from: "no-reply@example.com",
        to: request.form["email"] ?? "",
        subject: "Welcome",
        text: "Thanks for signing up.")

    return .redirect(to: "/")
}
```

For an HTML body, a reply-to address or reuse, build an `EmailMessage`:

```swift
let message = EmailMessage(
    from: "no-reply@example.com",
    to: "Ada Lovelace <ada@example.com>",
    subject: "Reset your password",
    textBody: "Open this link to reset: https://example.com/reset/…",
    htmlBody: "<p>Open <a href=\"https://example.com/reset/…\">this link</a> to reset.</p>",
    replyTo: "support@example.com")

try await request.bindings.mailer.send(message)
```

Addresses are plain `to@host` or `Name <to@host>`. `htmlBody` and `replyTo` are
optional.

## Plume-view email bodies

Scaffolded apps include a small `Mailer` extension that sends a Plume-rendered HTML
body with a plain-text fallback for clients that don't show HTML. Write the email as
a `.plume` component (e.g. `@component WelcomeEmail(name: String) { … }`), render
it and pass it in:

```swift
try await Mailer.current.send(
    to: user.email,
    subject: "Welcome",
    view: welcomeEmail(name: user.name),   // the rendered Plume component
    text: "Welcome, \(user.name)!")        // plain-text fallback
```

The helper builds the `EmailMessage` for you: `htmlBody` from the rendered view,
`textBody` from the fallback. The auth scaffold's verification and password-reset
emails (`Views/Emails/VerifyEmail.plume`, `Views/Emails/ResetEmail.plume`) are both sent
through exactly this helper.

## The protocol

An adapter conforms to `MailSender`: one method, deliver a message or throw:

```swift
public protocol MailSender: Sendable {
    func send(_ message: EmailMessage) async throws
}
```

The `Mailer` value carried on the request context is a concrete handle over such
an adapter, exposing:

```swift
public struct Mailer: Sendable {
    public init(_ adapter: some MailSender)
    public func send(_ message: EmailMessage) async throws
    public func send(from: String, to: String, subject: String, text: String) async throws
}
```

A failed send throws `MailError`, which carries a human-readable `message`
describing the failure (connection, auth or provider rejection). Wrap sends in
`do`/`catch` if a delivery failure should not fail the request:

```swift
do {
    try await mailer.send(message)
} catch let error as MailError {
    request.context.log("mail failed: \(error.message)")
}
```

## Native adapters

Two native drivers are available, selected by `[targets.native] mailer` in `plumekit.toml`.

### `log` (the development default)

The log driver prints the message instead of sending it, so you can see exactly what
would go out (verification links, reset links) without running a mail server:

```
[mail] ─────────────────────────────────────────
from:    no-reply@example.com
to:      ada@example.com
subject: Welcome
Thanks for signing up.
────────────────────────────────────────────────
```

### `smtp`

The `smtp` driver is a real SMTP client built on SwiftNIO. It is configured entirely
from the environment:

| Variable | Default | Purpose |
|---|---|---|
| `SMTP_HOST` | `127.0.0.1` | SMTP server host |
| `SMTP_PORT` | `1025` | SMTP server port |
| `SMTP_USERNAME` | *(unset)* | Optional; enables `AUTH LOGIN` |
| `SMTP_PASSWORD` | *(unset)* | Optional; used with the username |
| `MAIL_FROM` | `no-reply@localhost` | Default `From:` when a message omits one |

If both `SMTP_USERNAME` and `SMTP_PASSWORD` are set, the client authenticates with
`AUTH LOGIN`; otherwise it sends without authentication.

> **Limitation: no TLS/STARTTLS.** The native SMTP client speaks **plaintext** SMTP
> (plus optional `AUTH LOGIN`). It does **not** implement STARTTLS or implicit TLS,
> so credentials and message contents are sent unencrypted. This is fine for a local
> mail catcher (such as MailHog or `aiosmtpd`) or an unauthenticated relay on a
> trusted network. **Do not** use it to submit mail directly to a provider over the
> public internet; either put it behind a local relay that adds TLS, or use the
> Cloudflare adapter (which talks to an HTTPS provider API). TLS support is a planned
> addition.

## Cloudflare adapter

On the Cloudflare Worker target, the mailer serialises the message to JSON and hands
it to a `host_email_send` host import; the generated `worker.mjs` shim POSTs that
JSON to an HTTP email provider you configure (MailChannels, Resend, SendGrid or any
provider) via the `MAIL_API_URL` and `MAIL_API_KEY` bindings in `wrangler.toml`. The
provider-neutral JSON payload looks like:

```json
{ "from": "...", "to": "...", "subject": "...", "text": "...", "html": "...", "replyTo": "..." }
```

On the edge the send is **fire-and-forget**: the adapter conforms to the throwing
protocol but never throws; the JS shim logs any provider failure rather than
surfacing it back into the Wasm module. Design important flows (e.g. a password
reset) so the request succeeds even if the provider call fails, and rely on the shim
logs for delivery diagnostics.

## Portability at a glance

| | Native (`log`) | Native (`smtp`) | Cloudflare |
|---|---|---|---|
| Transport | prints to stdout | plaintext SMTP over NIO | HTTPS POST to a provider |
| Auth | none | optional `AUTH LOGIN` | provider API key |
| TLS | none | **none** | yes (provider HTTPS) |
| Throws on failure | no | yes (`MailError`) | no (shim logs) |
| Config | none | `SMTP_*`, `MAIL_FROM` | `MAIL_API_URL`, `MAIL_API_KEY` |

The `EmailMessage` you build and the `mailer.send(...)` you call are identical across
all three; only the selected adapter differs.
