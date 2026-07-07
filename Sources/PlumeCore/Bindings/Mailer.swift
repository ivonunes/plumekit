import _Concurrency

// MARK: - The Mailer capability
//
// Transactional email as a portable capability, alongside KV/Database/Queue/HTTP.
// The binding is "send this message"; adapters decide how:
//
//   • Native (PlumeServer): a log adapter (dev — prints the message) or a real
//     SMTP adapter (SwiftNIO).
//   • Edge (PlumeWorker): an adapter over a `host_email_send` import whose JS shim
//     POSTs to an HTTP email provider (MailChannels / Resend / SendGrid / …).
//
// The protocol names no provider and no transport — an app sends `EmailMessage`
// and the configured driver does the rest. Embedded-clean: concrete struct handle
// of an async closure, `String`/`[UInt8]` only, no Foundation.

/// A single outbound email. Addresses are plain `to@host` or `Name <to@host>`.
public struct EmailMessage: Sendable {
    public var from: String
    public var to: String
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var replyTo: String?

    public init(
        from: String,
        to: String,
        subject: String,
        textBody: String,
        htmlBody: String? = nil,
        replyTo: String? = nil
    ) {
        self.from = from
        self.to = to
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.replyTo = replyTo
    }

    /// The message as a JSON object — the wire form the edge adapter hands to its
    /// JS shim (provider-agnostic; the shim maps it to the provider's API).
    public func toJSON() -> JSONValue {
        var pairs: [(name: String, value: JSONValue)] = [
            ("from", .string(from)),
            ("to", .string(to)),
            ("subject", .string(subject)),
            ("text", .string(textBody)),
        ]
        if let htmlBody { pairs.append(("html", .string(htmlBody))) }
        if let replyTo { pairs.append(("replyTo", .string(replyTo))) }
        return .object(pairs)
    }
}

/// Raised by adapters when a send fails (connection, auth, provider rejection).
public struct MailError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// What a mail adapter implements. One method: deliver a message (or throw).
public protocol MailSender: Sendable {
    func send(_ message: EmailMessage) async throws
}

/// The Embedded-clean mailer handle carried in `Context`.
public struct Mailer: Sendable {
    private let _send: @Sendable (EmailMessage) async throws -> Void

    public init(_ adapter: some MailSender) { self._send = { try await adapter.send($0) } }
    public init(send: @escaping @Sendable (EmailMessage) async throws -> Void) { self._send = send }

    /// Deliver a message through the configured driver.
    public func send(_ message: EmailMessage) async throws { try await _send(message) }

    /// Convenience: build + send a plain-text message.
    public func send(from: String, to: String, subject: String, text: String) async throws {
        try await _send(EmailMessage(from: from, to: to, subject: subject, textBody: text))
    }
}
