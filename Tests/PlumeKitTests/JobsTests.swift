import Testing
@testable import PlumeCore
import PlumeServer

private actor Box {
    var value = ""
    func set(_ v: String) { value = v }
    func get() -> String { value }
}

private struct GreetJob: Job {
    static let name = "greet"
    let who: String
    init(who: String) { self.who = who }
    init(payload: [UInt8]) { self.who = decodeUTF8(payload) }
    func payload() -> [UInt8] { encodeUTF8(who) }
    func perform(_ context: Context) async throws {
        await context.kv?.putString("greeted", who)   // effect via a binding
    }
}

@Test func jobEnvelopeRoundTrips() {
    let envelope = encodeJobEnvelope("greet", encodeUTF8("ada"))
    let decoded = decodeJobEnvelope(envelope)
    #expect(decoded != nil)
    #expect(utf8Equal(decoded!.name, "greet"))
    #expect(decodeUTF8(decoded!.payload) == "ada")
}

@Test func enqueueDrainDispatchRunsJob() async throws {
    let inProcess = InProcessQueue()
    let queue = Queue(inProcess)
    let box = Box()
    let kv = KV(get: { _ in nil }, put: { _, value in await box.set(decodeUTF8(value)) })
    let context = Context(kv: kv, queue: queue)

    // Producer: enqueue a typed job.
    try await GreetJob(who: "ada").enqueue(on: queue)

    // Consumer: drain the in-process queue and dispatch via the registry.
    var registry = JobRegistry()
    registry.register(GreetJob.self)
    let batch = await inProcess.drain()
    #expect(batch.count == 1)
    for message in batch {
        let handled = try await registry.dispatch(message, context)
        #expect(handled)
    }
    #expect(await box.get() == "ada")   // the job ran and used the binding
}

@Test func unknownJobIsNotDispatched() async throws {
    let registry = JobRegistry()   // nothing registered
    let envelope = encodeJobEnvelope("nope", [])
    let handled = try await registry.dispatch(envelope, .empty)
    #expect(!handled)
}
