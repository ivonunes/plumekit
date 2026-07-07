import Foundation
import NIOCore
import NIOPosix
import PlumeCore

// Native mail adapters for the Mailer capability:
//   • LogMailer — prints the message (dev default; `native.mailer = "log"`).
//   • SMTPMailer — a real SMTP client over SwiftNIO (`native.mailer = "smtp"`),
//     configured from the environment (SMTP_HOST/PORT/USERNAME/PASSWORD, MAIL_FROM).
//
// This file is native-only (Foundation + NIO); the edge uses PlumeWorker's CFMailer.

/// Logs the message instead of sending it — the dev default, so you can see exactly
/// what would go out (reset links, verification links) without an SMTP server.
public struct LogMailer: MailSender {
    let log: @Sendable (String) -> Void
    public init(log: @escaping @Sendable (String) -> Void = { print($0) }) { self.log = log }
    public func send(_ message: EmailMessage) async throws {
        log("""
        [mail] ─────────────────────────────────────────
        from:    \(message.from)
        to:      \(message.to)
        subject: \(message.subject)
        \(message.textBody)
        ────────────────────────────────────────────────
        """)
    }
}

/// A real SMTP client (plaintext + optional AUTH LOGIN) over SwiftNIO. Enough to
/// deliver to a local catcher (aiosmtpd / MailHog) or an unauthenticated relay;
/// STARTTLS/implicit-TLS is a documented follow-up (add NIOSSL).
public struct SMTPMailer: MailSender {
    let host: String
    let port: Int
    let username: String?
    let password: String?
    let defaultFrom: String

    public init(host: String, port: Int, username: String?, password: String?, defaultFrom: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.defaultFrom = defaultFrom
    }

    public func send(_ message: EmailMessage) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: host, port: port) { ch in
                ch.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: ch)
                }
            }

        try await channel.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            var acc = ""
            func expect(_ codes: Int...) async throws {
                let code = try await Self.readResponse(&iterator, &acc)
                guard codes.contains(code) else {
                    throw MailError("SMTP \(host):\(port) expected \(codes) got \(code)")
                }
            }
            func cmd(_ line: String) async throws {
                var buf = ByteBuffer()
                buf.writeString(line + "\r\n")
                try await outbound.write(buf)
            }

            try await expect(220)                                   // greeting
            try await cmd("EHLO plumekit"); try await expect(250)
            if let username, let password {
                try await cmd("AUTH LOGIN"); try await expect(334)
                try await cmd(Data(username.utf8).base64EncodedString()); try await expect(334)
                try await cmd(Data(password.utf8).base64EncodedString()); try await expect(235)
            }
            let from = Self.address(message.from.isEmpty ? defaultFrom : message.from)
            try await cmd("MAIL FROM:<\(from)>"); try await expect(250)
            try await cmd("RCPT TO:<\(Self.address(message.to))>"); try await expect(250, 251)
            try await cmd("DATA"); try await expect(354)
            var body = ByteBuffer()
            body.writeString(Self.buildMessage(message, defaultFrom: defaultFrom))
            try await outbound.write(body)
            try await expect(250)                                   // message accepted
            try await cmd("QUIT")
        }
    }

    /// Read one complete SMTP reply (handles multi-line `250-…` continuations) and
    /// return its status code. Accumulates across TCP chunks.
    static func readResponse(
        _ iterator: inout NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator,
        _ acc: inout String
    ) async throws -> Int {
        while true {
            if let (code, consumed) = parseComplete(acc) {
                acc = String(acc.dropFirst(consumed))
                return code
            }
            guard let buffer = try await iterator.next() else { throw MailError("SMTP connection closed") }
            acc += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        }
    }

    /// If `acc` holds a complete reply, return (code, chars-consumed). A reply is
    /// complete at the first line whose 4th char is a space (not `-`).
    static func parseComplete(_ acc: String) -> (code: Int, consumed: Int)? {
        var offset = 0
        var search = Substring(acc)
        while let nl = search.range(of: "\r\n") {
            let line = search[search.startIndex..<nl.lowerBound]
            let lineLen = acc.distance(from: line.startIndex, to: line.endIndex)
            let chars = Array(line)
            if chars.count >= 4, chars[3] == " ", let code = Int(String(chars[0..<3])) {
                return (code, offset + lineLen + 2)
            }
            offset += lineLen + 2
            search = search[nl.upperBound...]
        }
        return nil
    }

    /// Extract the bare address from `Name <a@b>` or return the string as-is.
    static func address(_ value: String) -> String {
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            return String(value[value.index(after: open)..<close])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// RFC 5322 headers + body, CRLF line endings, dot-stuffed, terminated by `.`.
    static func buildMessage(_ m: EmailMessage, defaultFrom: String) -> String {
        var out = ""
        out += "From: \(m.from.isEmpty ? defaultFrom : m.from)\r\n"
        out += "To: \(m.to)\r\n"
        out += "Subject: \(m.subject)\r\n"
        if let replyTo = m.replyTo { out += "Reply-To: \(replyTo)\r\n" }
        out += "MIME-Version: 1.0\r\n"
        out += "Content-Type: text/plain; charset=utf-8\r\n"
        out += "\r\n"
        // Normalise to CRLF and dot-stuff lines beginning with '.'.
        let normalised = m.textBody.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            out += (line.hasPrefix(".") ? "." : "") + line + "\r\n"
        }
        out += ".\r\n"
        return out
    }
}
