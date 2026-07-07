import _Concurrency

// MARK: - The Queue capability
//
// "Scheduled / background / durable work" as a portable concept — the binding is
// enqueueing a message; consumers are the jobs layer. Adapters: Cloudflare Queues
// (wasm, JSPI) and a native in-process queue. The protocol names no platform
// primitive (no Cron, no SQS).

/// What a queue adapter implements. Bodies are opaque `[UInt8]` (a Codable job
/// payload encodes to bytes in the jobs layer).
public protocol MessageQueue: Sendable {
    func send(_ body: [UInt8]) async throws
}

/// The Embedded-clean queue handle carried in `Context`.
public struct Queue: Sendable {
    private let _send: @Sendable ([UInt8]) async throws -> Void

    public init(_ adapter: some MessageQueue) {
        self._send = { try await adapter.send($0) }
    }
    public init(send: @escaping @Sendable ([UInt8]) async throws -> Void) {
        self._send = send
    }

    public func send(_ body: [UInt8]) async throws { try await _send(body) }
    public func send(_ text: String) async throws { try await _send(encodeUTF8(text)) }
}
