import PlumeCore

// An example background job. Auto-registered by codegen (any `Job` under Sources/App/Jobs/
// is discovered — no manual registration). `perform` runs in the consumer (the Cloudflare
// queue consumer on the edge, or the native drainer) with a Context, so it reaches
// bindings like KV — here it records that it ran so a request can observe it.
struct LogJob: Job {
    static let name = "log"
    let message: String

    init(message: String) { self.message = message }
    init(payload: [UInt8]) { self.message = decodeUTF8(payload) }
    func payload() -> [UInt8] { encodeUTF8(message) }

    func perform(_ context: Context) async throws {
        await context.kv?.putString("last-job", message)
        context.log("job ran: \(message)")
    }
}
