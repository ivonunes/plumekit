import _Concurrency

// Streaming bodies, both directions, portable by construction:
//
//   • A RESPONSE can carry a producer closure instead of buffered bytes. The
//     native server streams it as chunked transfer encoding; adapters whose
//     transport is a single buffer (the Worker ABI, Lambda, the test client)
//     collect it — the same handler runs everywhere.
//   • A streaming-body ROUTE (`app.post("/upload", body: .streaming) { … }`)
//     reads its request body incrementally through `request.bodyReader` instead
//     of a buffered `request.body`. Native delivers live chunks with real
//     backpressure (and no 32 MB buffered-body cap); buffered adapters hand the
//     handler a one-shot replay of the bytes they already hold.
//
// Everything here is concrete value types and closures — no existentials, no
// AsyncSequence conformances — so it compiles under Embedded Swift.

/// How a route receives its request body. `.buffered` (the default) is the whole
/// body as `request.body`; `.streaming` delivers chunks through
/// `request.bodyReader` — for uploads that shouldn't sit in memory.
///
/// A streaming route's `request.body` is EMPTY, so anything that reads it —
/// `request.form`, multipart parsing, the CSRF form field — sees nothing. Protect
/// streaming endpoints with a bearer token or the CSRF header instead.
public enum RequestBodyMode: Sendable {
    case buffered
    case streaming
}

/// Pull-based reader over a streaming request body: `next()` returns the next
/// chunk, or nil at the end.
///
///     while let chunk = try await reader.next() { try handle(chunk) }
public struct RequestBodyReader: Sendable {
    let nextChunk: @Sendable () async throws -> [UInt8]?

    public init(next: @escaping @Sendable () async throws -> [UInt8]?) {
        self.nextChunk = next
    }

    /// The next chunk, or nil once the body is fully delivered.
    public func next() async throws -> [UInt8]? {
        try await nextChunk()
    }

    /// A reader that replays an already-buffered body as one chunk — what
    /// buffered adapters hand a streaming route.
    public static func replaying(_ body: [UInt8]) -> RequestBodyReader {
        let box = ReplayBox(body)
        return RequestBodyReader { box.take() }
    }
}

/// One-shot replay state. `@unchecked`: a reader is consumed by one handler task.
private final class ReplayBox: @unchecked Sendable {
    private var remaining: [UInt8]?
    init(_ body: [UInt8]) { remaining = body.isEmpty ? nil : body }
    func take() -> [UInt8]? {
        defer { remaining = nil }
        return remaining
    }
}

/// The writer a streaming response's producer writes chunks into.
public struct ResponseBodyWriter: Sendable {
    let writeChunk: @Sendable ([UInt8]) async throws -> Void

    public init(write: @escaping @Sendable ([UInt8]) async throws -> Void) {
        self.writeChunk = write
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await writeChunk(bytes)
    }

    public func write(_ text: String) async throws {
        try await writeChunk(encodeUTF8(text))
    }
}

extension Response {
    /// A response whose body is produced incrementally. The native server sends
    /// each written chunk to the client as it comes (chunked transfer encoding);
    /// buffered transports run the producer to completion and send the result —
    /// handler code is identical on every target.
    ///
    ///     return .stream(contentType: "text/csv") { writer in
    ///         try await writer.write("id,title\n")
    ///         for post in try await Post.all() {
    ///             try await writer.write("\(post.id),\(post.title)\n")
    ///         }
    ///     }
    public static func stream(
        contentType: String,
        status: Int = 200,
        headers: Headers = Headers(),
        _ produce: @escaping @Sendable (ResponseBodyWriter) async throws -> Void
    ) -> Response {
        var response = Response(status: status, headers: headers)
        if response.headers.first("content-type") == nil {
            response.headers.set("content-type", contentType)
        }
        response.bodyStream = produce
        return response
    }

    /// Run a streamed body to completion into a buffered response (the identity
    /// for already-buffered responses). Buffered transports call this at their
    /// boundary; a thrown producer error propagates like a thrown handler error.
    public func collectingStream() async throws -> Response {
        guard let bodyStream else { return self }
        let box = CollectedBody()
        try await bodyStream(ResponseBodyWriter(write: { box.append($0) }))
        var collected = self
        collected.body = box.bytes
        collected.bodyStream = nil
        return collected
    }
}

/// Accumulates a collected stream. `@unchecked`: the producer writes sequentially.
private final class CollectedBody: @unchecked Sendable {
    private(set) var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) { bytes.append(contentsOf: chunk) }
}
