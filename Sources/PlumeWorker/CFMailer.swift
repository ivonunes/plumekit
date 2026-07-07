// Cloudflare mail adapter — the Mailer for the Wasm target. Serializes the message
// to JSON and hands it to a `host_email_send` import; the worker.mjs shim POSTs it
// to the configured HTTP email provider (MAIL_API_URL / MAIL_API_KEY). Async via JSPI.
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

@_extern(wasm, module: "env", name: "host_email_send")
func host_email_send(_ ctx: Int32, _ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> Int32

struct CFMailer: MailSender {
    let ctx: Int32
    // Fire-and-forget: embedded Swift can't box a thrown error into `any Error`, so like the other
    // edge adapters we don't throw here — the JS shim logs provider failures. (Conforms to the
    // `throws` requirement without ever throwing.)
    func send(_ message: EmailMessage) async throws {
        let json = message.toJSON().serialize()
        _ = json.withUnsafeBufferPointer { host_email_send(ctx, $0.baseAddress, Int32($0.count)) }
    }
}
#endif
