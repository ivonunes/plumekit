import PlumeCore

/// A rendezvous channel carrying a streaming request body from the connection
/// loop to the handler, one chunk in flight at a time. `send` suspends until the
/// handler consumes the chunk, so backpressure reaches TCP for free: while the
/// handler is busy, the loop isn't reading, and the client's send window fills.
///
/// The handler may return before consuming everything (an early rejection);
/// `consumerFinished()` then unblocks the loop, which discards the remaining
/// chunks on the floor instead of deadlocking.
actor BodyPipe {
    private var pending: [UInt8]?
    private var finished = false
    private var failed = false
    private var consumerGone = false
    private var senderWaiter: CheckedContinuation<Void, Never>?
    private var readerWaiter: CheckedContinuation<[UInt8]?, any Error>?

    /// Deliver one chunk, suspending until it is consumed (or dropped because the
    /// handler already returned).
    func send(_ chunk: [UInt8]) async {
        if consumerGone || finished || failed { return }
        if let reader = readerWaiter {
            readerWaiter = nil
            reader.resume(returning: chunk)
            return
        }
        pending = chunk
        await withCheckedContinuation { senderWaiter = $0 }
    }

    /// The body is complete; a waiting (or future) `next()` returns nil.
    func finish() {
        finished = true
        if let reader = readerWaiter {
            readerWaiter = nil
            reader.resume(returning: nil)
        }
    }

    /// The client vanished mid-body (disconnect, timeout): the handler must NOT
    /// mistake what arrived for the whole body, so `next()` throws from here on —
    /// and a handler suspended in `next()` is woken now rather than leaking with
    /// the connection.
    func fail() {
        failed = true
        pending = nil
        if let reader = readerWaiter {
            readerWaiter = nil
            reader.resume(throwing: RequestBodyIncomplete())
        }
    }

    /// The handler's pull side.
    func next() async throws -> [UInt8]? {
        if failed { throw RequestBodyIncomplete() }
        if let chunk = pending {
            pending = nil
            if let sender = senderWaiter {
                senderWaiter = nil
                sender.resume()
            }
            return chunk
        }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { readerWaiter = $0 }
    }

    /// The handler returned — release a suspended sender and drop what's left.
    func consumerFinished() {
        consumerGone = true
        pending = nil
        if let sender = senderWaiter {
            senderWaiter = nil
            sender.resume()
        }
    }
}

/// The connection carrying a streaming request body died before `.end` arrived.
struct RequestBodyIncomplete: Error, CustomStringConvertible {
    var description: String { "request body ended before it was complete (client disconnected or stalled)" }
}
