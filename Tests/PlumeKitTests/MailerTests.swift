import Testing
import Foundation
@testable import PlumeCore
@testable import PlumeServer

/// A test double that records what it was asked to send.
final class RecordingMailer: MailSender, @unchecked Sendable {
    var sent: [EmailMessage] = []
    var shouldFail = false
    func send(_ message: EmailMessage) async throws {
        if shouldFail { throw MailError("boom") }
        sent.append(message)
    }
}

@Test func mailerHandleForwardsToAdapter() async throws {
    let recorder = RecordingMailer()
    let mailer = Mailer(recorder)
    try await mailer.send(from: "a@x", to: "b@y", subject: "Hi", text: "body")
    #expect(recorder.sent.count == 1)
    #expect(recorder.sent[0].to == "b@y")
    #expect(recorder.sent[0].subject == "Hi")
    #expect(recorder.sent[0].textBody == "body")
}

@Test func mailerPropagatesAdapterFailure() async throws {
    let recorder = RecordingMailer()
    recorder.shouldFail = true
    let mailer = Mailer(recorder)
    await #expect(throws: MailError.self) {
        try await mailer.send(EmailMessage(from: "a@x", to: "b@y", subject: "s", textBody: "t"))
    }
}

@Test func emailMessageSerializesToJSON() {
    let message = EmailMessage(from: "a@x", to: "b@y", subject: "Subj", textBody: "Body",
                              htmlBody: "<b>Body</b>", replyTo: "r@z")
    let json = message.toJSON().serialize()
    let text = PlumeCore.decodeUTF8(json)
    #expect(text.contains("\"from\":\"a@x\""))
    #expect(text.contains("\"to\":\"b@y\""))
    #expect(text.contains("\"subject\":\"Subj\""))
    #expect(text.contains("\"text\":\"Body\""))
    #expect(text.contains("\"html\":"))
    #expect(text.contains("\"replyTo\":\"r@z\""))
}

final class LogCollector: @unchecked Sendable { var text = "" }

@Test func logMailerDoesNotThrow() async throws {
    let collector = LogCollector()
    let mailer = Mailer(LogMailer(log: { collector.text += $0 }))
    try await mailer.send(from: "a@x", to: "b@y", subject: "Hello", text: "the body")
    #expect(collector.text.contains("b@y"))
    #expect(collector.text.contains("Hello"))
}

@Test func smtpMessageBuilderProducesRFC5322() {
    let message = EmailMessage(from: "From <f@x>", to: "t@y", subject: "S", textBody: "line1\n.dotted\nline3")
    let raw = SMTPMailer.buildMessage(message, defaultFrom: "d@x")
    #expect(raw.contains("From: From <f@x>\r\n"))
    #expect(raw.contains("To: t@y\r\n"))
    #expect(raw.contains("Subject: S\r\n"))
    #expect(raw.contains("\r\n\r\n"))          // header/body separator
    #expect(raw.contains("\r\n..dotted\r\n"))  // dot-stuffed leading '.'
    #expect(raw.hasSuffix(".\r\n"))            // terminating dot
    #expect(SMTPMailer.address("Name <a@b>") == "a@b")
    #expect(SMTPMailer.parseComplete("250 ok\r\n")?.code == 250)
    #expect(SMTPMailer.parseComplete("250-first\r\n250 done\r\n")?.code == 250)
    #expect(SMTPMailer.parseComplete("250-partial\r\n") == nil)
}
