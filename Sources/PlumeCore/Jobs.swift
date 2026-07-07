import _Concurrency

// Background jobs: typed work units enqueued via the Queue producer and
// run by a consumer (the native drainer or the Cloudflare queue consumer). The
// job system is platform-neutral and Embedded-clean: dispatch routes by an ASCII
// job name compared byte-wise, payloads are `[UInt8]`, and
// the registry holds concrete closures — no existentials, no reflection.

/// A unit of background work. Conformers serialize their args to bytes and
/// reconstruct from them; `perform` does the work with the request/consumer
/// `Context` (so jobs reach KV/DB/storage/etc. like handlers do).
// `Sendable`: a job is serialized, enqueued, deserialized and run in a consumer, so it
// crosses concurrency domains — and `register` captures its metatype in a `@Sendable`
// closure. Real jobs are value-type structs, so this is satisfied automatically.
public protocol Job: Sendable {
    static var name: String { get }
    init(payload: [UInt8])
    func payload() -> [UInt8]
    func perform(_ context: Context) async throws
}

extension Job {
    /// Serialize into an envelope and enqueue on the platform queue.
    public func enqueue(on queue: Queue) async throws {
        try await queue.send(encodeJobEnvelope(Self.name, payload()))
    }
}

// MARK: - Wire envelope: [u16 nameLen][name UTF-8][payload]

public func encodeJobEnvelope(_ name: String, _ payload: [UInt8]) -> [UInt8] {
    let nameBytes = Array(name.utf8)
    var out: [UInt8] = []
    out.append(UInt8(truncatingIfNeeded: nameBytes.count >> 8))
    out.append(UInt8(truncatingIfNeeded: nameBytes.count))
    out.append(contentsOf: nameBytes)
    out.append(contentsOf: payload)
    return out
}

public func decodeJobEnvelope(_ bytes: [UInt8]) -> (name: String, payload: [UInt8])? {
    guard bytes.count >= 2 else { return nil }
    let nameLength = Int(bytes[0]) << 8 | Int(bytes[1])
    guard bytes.count >= 2 + nameLength else { return nil }
    let name = decodeUTF8(Array(bytes[2..<(2 + nameLength)]))
    let payload = Array(bytes[(2 + nameLength)...])
    return (name, payload)
}

// MARK: - Registry + dispatch

/// Maps job names to type-erased run closures. Built once at startup (the worker
/// and native server are single-threaded for this), then used to dispatch.
public struct JobRegistry: @unchecked Sendable {
    private var handlers: [(name: String, run: @Sendable ([UInt8], Context) async throws -> Void)] = []

    public init() {}

    public mutating func register<J: Job>(_ type: J.Type) {
        handlers.append((name: J.name, run: { payload, context in
            try await J(payload: payload).perform(context)
        }))
    }

    /// Register a closure under an explicit envelope name (framework plumbing —
    /// e.g. the schedule tick; apps use `register(_ type:)` with a `Job`).
    public mutating func register(name: String,
                                  _ run: @escaping @Sendable ([UInt8], Context) async throws -> Void) {
        handlers.append((name: name, run: run))
    }

    /// Decode an envelope and run the matching job. Returns false for an unknown
    /// job name (the caller can log/ack it).
    @discardableResult
    public func dispatch(_ envelope: [UInt8], _ context: Context) async throws -> Bool {
        guard let (name, payload) = decodeJobEnvelope(envelope) else { return false }
        for handler in handlers where utf8Equal(handler.name, name) {
            // Bind the job's context as ambient so a job body can use `Post.save()`,
            // `KV.current`, `Cache.current`, … without threading `context` through
            // (the same convenience a request handler has). Task-local on native,
            // plain global on the embedded guest — see `RequestContext`.
            #if hasFeature(Embedded)
            RequestContext.current = context
            try await handler.run(payload, context)
            #else
            try await RequestContext.withValue(context) {
                try await handler.run(payload, context)
            }
            #endif
            return true
        }
        return false
    }
}
