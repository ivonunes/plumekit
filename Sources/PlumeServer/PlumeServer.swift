// `@preconcurrency`: `stdout`/`stderr` are shared-mutable C globals, which Swift 6 strict
// concurrency flags on Glibc; this lets `setvbuf(stdout, …)` below compile there (Darwin is
// unaffected either way).
#if canImport(Darwin)
@preconcurrency import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#endif
import Foundation
import PlumeCore
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// The native HTTP/1.1 server that drives a PlumeKit `Application`, built on
/// **SwiftNIO** — the reference native transport. NIO parses requests and
/// serializes responses; the portable core (`Application`) carries all routing.
/// Each connection is handled on its own task; handlers run `async`, so KV /
/// SQLite / blob bindings `await` naturally.
public enum PlumeServer {
    /// Hard cap on a buffered request body (32 MB) — a request over this gets 413 instead
    /// of being buffered whole, so an oversized or lying `Content-Length` can't OOM the
    /// process. Large uploads should stream to storage rather than raise this.
    static let maxRequestBodyBytes = 32 * 1024 * 1024

    /// A connection that hasn't finished sending its request HEADERS within this window is
    /// closed (slow-loris defense). The clock stops the instant the header terminator
    /// (`\r\n\r\n`) is seen, so a normal request, an SSE stream, or a WebSocket upgrade is
    /// never affected — only a client that withholds or dribbles its headers. `var` so
    /// tests can shorten it.
    nonisolated(unsafe) static var requestHeadTimeoutMillis = 15_000

    /// The body-side counterpart: a request BODY that stalls for this long between
    /// chunks closes the connection (armed at the head, reset per chunk, disarmed at
    /// `.end`). Without it, a dribbling upload — especially on an uncapped streaming
    /// route — holds a handler task open indefinitely. `var` so tests can shorten it.
    nonisolated(unsafe) static var requestBodyIdleTimeoutMillis = 60_000

    /// Bind to `host:port` and serve `app` forever. `context` carries the native
    /// bindings (KV/DB/blob/queue/http), reused across requests.
    // A connection is negotiated into one of these by the upgradable pipeline.
    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, room: String, kind: PayloadKind, token: String?)
        case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>)
    }

    public static func run(
        _ app: Application,
        host: String = "127.0.0.1",
        port: UInt16 = 8080,
        context: Context = .empty,
        jobs: JobRegistry? = nil,
        channels: ChannelHub? = nil,
        publicDirectory: String? = nil,
        schedule: Schedule? = nil
    ) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer logs under `plumekit serve`
        NativeDrivers.installNativeClock()  // ORM createdAt/updatedAt source

        // Static files: serve the project's `Public/` directory (by convention) when it
        // exists. Resolved once (absolute, symlink-free) so per-request containment
        // checks are cheap and can't be fooled by a changing working directory.
        let publicRoot = StaticFiles.resolveRoot(publicDirectory ?? "Public")
        if let publicRoot { print("Serving static files from \(publicRoot)") }

        // The native job consumer: drain the in-process queue and dispatch jobs in
        // the background. The same JobRegistry the Cloudflare queue consumer uses.
        if let jobs, let queue = NativeDrivers.sharedInProcessQueue {
            Task { await drainJobs(jobs, queue, context) }
        }

        // The native schedule ticker: once a minute, on the boundary — the same tick
        // a Cloudflare Cron Trigger or EventBridge rule delivers on the other targets.
        if let schedule, !schedule.entries.isEmpty {
            Task {
                while !Task.isCancelled {
                    let now = Int64(Date().timeIntervalSince1970)
                    let secondsToNextMinute = 60 - (now % 60)
                    try? await Task.sleep(nanoseconds: UInt64(secondsToNextMinute) * 1_000_000_000)
                    await schedule.runDue(atEpochSeconds: Int64(Date().timeIntervalSince1970),
                                          context: context)
                }
            }
        }

        // Signed subscriptions: when a channel signing key is configured, every
        // subscribe must present a valid channel-scoped token (verified below). A
        // `let` so the accept-loop child tasks can capture it without a data race.
        let channelSigningKey: [UInt8]? = await {
            guard let secrets = context.secrets else { return nil }
            return try? await secrets.secret("CHANNEL_SIGNING_KEY")
        }()

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

        // Upgradable pipeline: a request with `Upgrade: websocket` becomes a
        // WebSocket connection (→ the channel hub); everything else stays HTTP.
        let serverChannel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> =
            try await bootstrap.bind(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Slow-loris guard at the pipeline HEAD (before HTTP decoding), so it's
                    // active from connect and cancels itself once the request headers land.
                    try channel.pipeline.syncOperations.addHandler(
                        SlowRequestHeadTimeout(timeout: .milliseconds(Int64(Self.requestHeadTimeoutMillis))))
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        shouldUpgrade: { channel, head in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                let ws = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel)
                                return UpgradeResult.websocket(
                                    ws, room: queryValue(head.uri, "room") ?? "default",
                                    kind: queryValue(head.uri, "kind") == "payload" ? .payload : .fragment,
                                    token: queryValue(head.uri, "token"))
                            }
                        }
                    )
                    let config = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                // Body-idle guard on the HTTP path (WebSocket pipelines
                                // never see it): sits above the decoder, so it watches
                                // typed parts, not raw bytes.
                                try channel.pipeline.syncOperations.addHandler(
                                    RequestBodyIdleTimeout(timeout: .milliseconds(Int64(Self.requestBodyIdleTimeoutMillis))))
                                let http = try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                                    wrappingChannelSynchronously: channel)
                                return UpgradeResult.notUpgraded(http)
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: config))
                }
            }

        print("PlumeKit serving on http://\(host):\(port) — press Ctrl+C to stop")

        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel.executeThenClose { inbound in
                for try await negotiation in inbound {
                    group.addTask {
                        do {
                            switch try await negotiation.get() {
                            case .notUpgraded(let http):
                                try? await handleConnection(http, app: app, context: context,
                                                            channels: channels, publicRoot: publicRoot,
                                                            channelSigningKey: channelSigningKey)
                            case .websocket(let ws, let room, let kind, let token):
                                if let channels {
                                    try? await handleWebSocket(ws, room: room, kind: kind, token: token,
                                                               hub: channels, signingKey: channelSigningKey)
                                }
                            }
                        } catch {}
                    }
                }
            }
        }
    }

    /// A WebSocket connection: subscribe to the room's channel, fan inbound text
    /// frames into the hub (which fans the result back out to all subscribers).
    private static func handleWebSocket(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        room: String,
        kind: PayloadKind,
        token: String?,
        hub: ChannelHub,
        signingKey: [UInt8]?
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            // Signed subscriptions: when a signing key is configured, reject any
            // subscribe without a valid channel-scoped token (timing-safe in verify).
            if let key = signingKey {
                let now = Int(time(nil))
                guard let token,
                      ChannelToken.verify(token, channel: ChannelID(room), now: now, key: key) else {
                    try? await outbound.write(WebSocketFrame(
                        fin: true, opcode: .connectionClose, data: channel.channel.allocator.buffer(capacity: 0)))
                    return
                }
            }
            // The socket's subject — verified above when a signing key is
            // configured; adopted as-is (dev mode) otherwise.
            let subject = token.flatMap { ChannelToken.subject($0) } ?? ""
            // The hub holds a send closure that writes a text frame to this socket.
            let id = await hub.subscribe(room: room, kind: kind, subject: subject) { bytes in
                var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                try? await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
            }
            defer { Task { await hub.unsubscribe(room: room, id: id) } }

            for try await frame in inbound {
                switch frame.opcode {
                case .text, .binary:
                    var data = frame.unmaskedData
                    let bytes = data.readBytes(length: data.readableBytes) ?? []
                    // Keepalive: a literal "ping" is answered right here, without
                    // dispatching the channel (mirrors the Cloudflare adapter's
                    // hibernation auto-response, where a ping never wakes the DO).
                    // Clients use it to hold idle sockets open for free.
                    if bytes == Array("ping".utf8) {
                        var buffer = ByteBufferAllocator().buffer(capacity: 4)
                        buffer.writeBytes(Array("pong".utf8))
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: buffer))
                        continue
                    }
                    await hub.handle(room: room, message: bytes, subject: subject)
                case .ping:
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                case .connectionClose:
                    return
                default:
                    break
                }
            }
        }
    }

    /// Extract a query value from an upgrade URI (native — String ops OK).
    private static func queryValue(_ uri: String, _ name: String) -> String? {
        guard let q = uri.firstIndex(of: "?") else { return nil }
        for pair in uri[uri.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    /// Background loop: drain the in-process queue and dispatch each message
    /// through the registry. Runs alongside the HTTP server for the process life.
    private static func drainJobs(_ registry: JobRegistry, _ queue: InProcessQueue, _ context: Context) async {
        while true {
            for message in await queue.drain() {
                do {
                    _ = try await registry.dispatch(message, context)
                } catch {
                    // The in-process drainer has no retry/dead-letter (unlike the
                    // Cloudflare queue); surface the failure instead of dropping it silently.
                    context.log("job failed: \(error)")
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func handleConnection(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        app: Application,
        context: Context,
        channels: ChannelHub?,
        publicRoot: String?,
        channelSigningKey: [UInt8]?
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body: [UInt8] = []
            var streaming: (pipe: BodyPipe, task: Task<Response, Never>)?
            var sse: (room: String, id: Int)?
            // The loop can end abnormally (client disconnect, a reset, the body-idle
            // guard closing the channel) — the cleanup below must run on EVERY exit:
            // a streaming handler suspended on its pipe would otherwise leak forever,
            // and an SSE subscriber would stay in the hub.
            var iterationError: (any Error)?
            do {
            receive: for try await part in inbound {
                switch part {
                case .head(let h):
                    head = h
                    body.removeAll()   // capacity was released after the last response anyway
                    // A `.streaming` route gets its handler started NOW, fed live
                    // chunks through a rendezvous pipe (no buffering, no body cap —
                    // that's the point). Everything else buffers as usual.
                    if let method = plumekitMethod(h.method),
                       method == .post || method == .put || method == .patch,
                       app.requestBodyMode(method, splitURI(h.uri).0) == .streaming {
                        let pipe = BodyPipe()
                        let reader = RequestBodyReader { try await pipe.next() }
                        let task = Task {
                            let response = await respond(head: h, body: [], reader: reader,
                                                         app: app, context: context)
                            await pipe.consumerFinished()
                            return response
                        }
                        streaming = (pipe, task)
                        break
                    }
                    // Reserve from the declared length so a large upload appends into
                    // one allocation instead of growing through reallocation-copies.
                    // Clamped to the cap: a lying Content-Length can't reserve 32 MB+.
                    if let declared = h.headers.first(name: "content-length").flatMap({ Int($0) }),
                       declared > 0 {
                        body.reserveCapacity(min(declared, Self.maxRequestBodyBytes))
                    }
                case .body(let chunk):
                    if let streaming {
                        await streaming.pipe.send([UInt8](chunk.readableBytesView))
                        break
                    }
                    // Cap the buffered body so a huge (or lying `Content-Length`) upload
                    // can't OOM the server. Once over, answer 413 and close — mid-body
                    // there is no reliable way to resync the connection for reuse. Drain
                    // (bounded) what the client is still sending before closing: an
                    // immediate close while data is in flight makes the kernel RST, and
                    // the client then reports a reset instead of ever seeing the 413.
                    if body.count + chunk.readableBytes > Self.maxRequestBodyBytes {
                        try await write(Response.text("413 Payload Too Large", status: 413),
                                        to: outbound, keepAlive: false)
                        var drained = 0
                        for try await part in inbound {
                            if case .end = part { break }
                            if case .body(let extra) = part {
                                drained += extra.readableBytes
                                if drained > Self.maxRequestBodyBytes { break }   // don't linger forever
                            }
                        }
                        break receive
                    }
                    body.append(contentsOf: chunk.readableBytesView)
                case .end:
                    guard let h = head else { break }
                    if let current = streaming {
                        await current.pipe.finish()
                        let response = await current.task.value
                        let keepAlive = h.isKeepAlive && channels == nil
                        let acceptsGzip = h.headers.first(name: "accept-encoding")
                            .map { $0.lowercased().contains("gzip") } ?? false
                        try await write(response, to: outbound, keepAlive: keepAlive,
                                        acceptsGzip: acceptsGzip)
                        streaming = nil
                        head = nil
                        if !keepAlive { break receive }
                        break
                    }
                    // SSE: a one-way server→client stream over HTTP. Simpler
                    // than WebSockets — no coordination/DO needed; the hub feeds it.
                    if let channels, h.method == .GET, pathComponent(h.uri) == "/sse" {
                        let room = queryValue(h.uri, "room") ?? "default"
                        let token = queryValue(h.uri, "token")
                        // Signed subscriptions gate SSE exactly like WebSockets: with a
                        // signing key configured, no valid channel-scoped token → no stream.
                        if let key = channelSigningKey {
                            let now = Int(time(nil))
                            guard let token,
                                  ChannelToken.verify(token, channel: ChannelID(room), now: now, key: key) else {
                                try await write(Response.text("403 Forbidden", status: 403),
                                                to: outbound, keepAlive: false)
                                break receive
                            }
                        }
                        var headers = HTTPHeaders()
                        headers.add(name: "content-type", value: "text/event-stream")
                        headers.add(name: "cache-control", value: "no-cache")
                        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
                        let subject = token.flatMap { ChannelToken.subject($0) } ?? ""
                        let id = await channels.subscribe(room: room, kind: .fragment, subject: subject) { bytes in
                            var buffer = ByteBuffer()
                            buffer.writeString("data: ")
                            buffer.writeBytes(bytes)
                            buffer.writeString("\n\n")
                            try? await outbound.write(.body(.byteBuffer(buffer)))
                        }
                        sse = (room, id)   // stream until the client disconnects (inbound ends)
                    } else if isUpgradeRequest(h) {
                        // A WebSocket handshake on an already-negotiated HTTP connection
                        // (a client reusing a pooled keep-alive connection — Node's
                        // undici does this). NIO's upgrade handler only exists for a
                        // connection's FIRST request, so upgrading here is impossible;
                        // answer 426 and close so the connection leaves the client's pool.
                        try await write(Response.text("426 Upgrade Required", status: 426),
                                        to: outbound, keepAlive: false)
                        break receive
                    } else {
                        // HTTP/1.1 defaults to persistent connections; close only when the
                        // client asked to (or is HTTP/1.0 without keep-alive). With realtime
                        // channels enabled, every response closes instead: an idle kept-alive
                        // connection is a trap for WebSocket clients that reuse pooled
                        // connections for the handshake — the upgrade can only ever happen
                        // on a connection's first request (see above).
                        let keepAlive = h.isKeepAlive && channels == nil
                        let acceptsGzip = h.headers.first(name: "accept-encoding")
                            .map { $0.lowercased().contains("gzip") } ?? false
                        var served = false
                        if let publicRoot, let method = plumekitMethod(h.method),
                           method == .get || method == .head {
                            served = try await serveStatic(head: h, method: method, root: publicRoot,
                                                           eventLoop: channel.channel.eventLoop,
                                                           outbound: outbound, keepAlive: keepAlive,
                                                           acceptsGzip: acceptsGzip)
                        }
                        if !served {
                            let response = await respond(head: h, body: body, app: app, context: context)
                            try await write(response, to: outbound, keepAlive: keepAlive,
                                            acceptsGzip: acceptsGzip)
                        }
                        head = nil
                        body = []   // don't hold a request body across an idle keep-alive
                        if !keepAlive { break receive }
                    }
                }
            }
            } catch {
                iterationError = error
            }
            if let current = streaming { await current.pipe.fail() }
            if let sse { await channels?.unsubscribe(room: sse.room, id: sse.id) }
            if let iterationError { throw iterationError }
        }
    }

    /// Reads for static files run on NIO's thread pool, not the Swift cooperative
    /// pool — a large download must never starve request handling.
    private static let fileIO = NonBlockingFileIO(threadPool: .singleton)
    private static let fileChunkBytes = 128 * 1024

    /// Answer a GET/HEAD from `Public/` if the path maps to a file there: 304 when the
    /// client's validator still matches, otherwise the file streamed in fixed-size
    /// chunks (never buffered whole). Returns false to fall through to routes.
    /// Compressible static files up to this size are gzipped whole (text bundles
    /// are small); anything larger streams uncompressed rather than being buffered.
    private static let maxCompressibleFileBytes = 4 * 1024 * 1024

    private static func serveStatic(
        head h: HTTPRequestHead,
        method: PlumeCore.HTTPMethod,
        root: String,
        eventLoop: EventLoop,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        keepAlive: Bool,
        acceptsGzip: Bool
    ) async throws -> Bool {
        let (path, _) = splitURI(h.uri)
        guard let info = StaticFiles.lookup(requestPath: path, root: root) else { return false }

        let compressible = GzipCompression.isCompressibleContentType(info.contentType)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: info.contentType)
        headers.add(name: "cache-control", value: info.cacheControl)
        headers.add(name: "etag", value: info.etag)
        headers.add(name: "last-modified", value: info.lastModified)
        if compressible { headers.add(name: "vary", value: "Accept-Encoding") }
        headers.add(name: "connection", value: keepAlive ? "keep-alive" : "close")

        // `contains` covers both a single ETag and an `a, b, c` list from the client.
        if let match = h.headers.first(name: "if-none-match"), match.contains(info.etag) {
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .notModified,
                                                            headers: headers)))
            try await outbound.write(.end(nil))
            return true
        }

        let wantsCompressed = method == .get && compressible && acceptsGzip
            && info.size >= GzipCompression.minimumBytes && info.size <= Self.maxCompressibleFileBytes

        // The compressed representation is cached by ETag (a hit skips the disk
        // entirely — the same bundle file is requested on every page view).
        if wantsCompressed, let cached = GzipCompression.assetCache.lookup(info.etag) {
            headers.add(name: "content-encoding", value: "gzip")
            headers.add(name: "content-length", value: String(cached.count))
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
            var out = ByteBuffer()
            out.writeBytes(cached)
            try await outbound.write(.body(.byteBuffer(out)))
            try await outbound.write(.end(nil))
            return true
        }

        // Open BEFORE committing the response head: a file deleted or made
        // unreadable between stat and open then falls through to the app's routes
        // (a clean 404) instead of dying mid-response after a 200 is on the wire.
        var handle: NIOFileHandle? = nil
        if method == .get, info.size > 0 {
            guard let opened = try? StaticFiles.open(info.path) else { return false }
            handle = opened
        }

        // A compressible text asset for a gzip-capable client: read it whole (they
        // are small — the CSS/JS bundles this exists for), compress once, cache.
        if let openedHandle = handle, wantsCompressed {
            defer { StaticFiles.close(openedHandle) }
            let buffer = try await fileIO.read(fileHandle: openedHandle, fromOffset: 0,
                                               byteCount: info.size,
                                               allocator: ByteBufferAllocator(),
                                               eventLoop: eventLoop).get()
            guard buffer.readableBytes == info.size,
                  let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else {
                throw StaticFileTruncated()
            }
            var body = bytes
            if let compressed = GzipCompression.gzip(bytes), compressed.count < bytes.count {
                body = compressed
                headers.add(name: "content-encoding", value: "gzip")
                GzipCompression.assetCache.store(info.etag, compressed)
            }
            headers.add(name: "content-length", value: String(body.count))
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
            var out = ByteBuffer()
            out.writeBytes(body)
            try await outbound.write(.body(.byteBuffer(out)))
            try await outbound.write(.end(nil))
            return true
        }

        headers.add(name: "content-length", value: String(info.size))
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
        if let handle {
            // Chunked copies, not a FileRegion: the async writer completes a write on
            // ENQUEUE, so there is no safe point to close a sendfile descriptor.
            // Buffered chunks carry their own bytes — closing after the loop is safe
            // even while the tail is still flushing.
            defer { StaticFiles.close(handle) }
            let allocator = ByteBufferAllocator()
            var offset: Int64 = 0
            while offset < Int64(info.size) {
                let chunk = try await fileIO.read(
                    fileHandle: handle, fromOffset: offset,
                    byteCount: min(fileChunkBytes, Int(Int64(info.size) - offset)),
                    allocator: allocator, eventLoop: eventLoop).get()
                if chunk.readableBytes == 0 { break }
                offset += Int64(chunk.readableBytes)
                try await outbound.write(.body(.byteBuffer(chunk)))
            }
            // Truncated since stat: the promised Content-Length can't be honoured, so
            // fail the connection rather than desync a keep-alive stream.
            guard offset == Int64(info.size) else { throw StaticFileTruncated() }
        }
        try await outbound.write(.end(nil))
        return true
    }

    /// Whether a request head asks to switch protocols (RFC 9110 §7.8):
    /// `Connection: upgrade` + `Upgrade: websocket`.
    private static func isUpgradeRequest(_ head: HTTPRequestHead) -> Bool {
        let upgrades = head.headers[canonicalForm: "upgrade"]
        guard upgrades.contains(where: { $0.lowercased() == "websocket" }) else { return false }
        return head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
    }

    private static func pathComponent(_ uri: String) -> String {
        if let q = uri.firstIndex(of: "?") { return String(uri[uri.startIndex..<q]) }
        return uri
    }

    private static func respond(
        head: HTTPRequestHead,
        body: [UInt8],
        reader: RequestBodyReader? = nil,
        app: Application,
        context: Context
    ) async -> Response {
        guard let method = plumekitMethod(head.method) else {
            return Response.text("405 Method Not Allowed", status: 405)
        }
        let (path, query) = splitURI(head.uri)

        // Live-reload plumbing, development only: the boot-id poll endpoint, and
        // the poller injected into HTML pages below.
        if developmentMode, method == .get, path == DevReload.path {
            var response = Response.text(DevReload.bootID)
            response.headers.set("cache-control", "no-store")
            return response
        }

        var headers = Headers()
        for field in head.headers { headers.add(field.name, field.value) }
        var request = Request(method: method, path: path, query: query,
                              headers: headers, body: body, context: context)
        request.bodyReader = reader
        do {
            var response = try await app.handleThrowing(request)
            if developmentMode { response = DevReload.inject(into: response) }
            return response
        } catch {
            // Always log the error (a silent 500 helps nobody). In development, render
            // the full error page; in production, the clean 500.
            context.log("Unhandled error on \(method.name) \(path): \(String(describing: error))")
            if developmentMode {
                return DevErrorPage.response(error: error, request: request, routes: app.routeList)
            }
            return await app.renderErrorPage(500, for: request)
                ?? Response.text("500 Internal Server Error", status: 500)
        }
    }

    /// Development mode gates the dev error page. `plumekit serve`/`dev` set
    /// PLUMEKIT_ENV=development for you; deployed servers never see it.
    private static var developmentMode: Bool {
        ProcessInfo.processInfo.environment["PLUMEKIT_ENV"] == "development"
    }

    private static func write(
        _ response: Response,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        keepAlive: Bool,
        acceptsGzip: Bool = false
    ) async throws {
        var headers = HTTPHeaders()
        // Strip CR/LF/NUL from every header value so an attacker-influenced value (e.g. a
        // redirect Location or cookie built from user input) can't inject headers or split
        // the response. Defense-in-depth — the app should validate too, but the wire must be safe.
        for field in response.headers.fields {
            headers.add(name: field.name, value: field.value.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
        }

        // A streamed body: no Content-Length, so NIO's encoder frames it as chunked
        // transfer encoding — each written chunk reaches the client as it comes.
        // Compressible streams are gzipped INCREMENTALLY (each chunk sync-flushed
        // through the deflater), so promptness is preserved.
        if let produce = response.bodyStream {
            headers.remove(name: "content-length")
            let streamer: GzipCompression.Streamer? = {
                guard acceptsGzip, headers.first(name: "content-encoding") == nil,
                      let contentType = headers.first(name: "content-type"),
                      GzipCompression.isCompressibleContentType(contentType) else { return nil }
                return GzipCompression.Streamer()
            }()
            if streamer != nil {
                headers.add(name: "content-encoding", value: "gzip")
                if !headers.contains(name: "vary") { headers.add(name: "vary", value: "Accept-Encoding") }
            }
            headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
            let responseHead = HTTPResponseHead(
                version: .http1_1,
                status: HTTPResponseStatus(statusCode: response.status, reasonPhrase: response.reasonPhrase),
                headers: headers)
            try await outbound.write(.head(responseHead))
            try await produce(ResponseBodyWriter(write: { bytes in
                var out = bytes
                if let streamer {
                    guard let compressed = streamer.push(bytes) else { throw StreamCompressionFailed() }
                    out = compressed
                }
                if out.isEmpty { return }
                var buffer = ByteBuffer()
                buffer.writeBytes(out)
                try await outbound.write(.body(.byteBuffer(buffer)))
            }))
            if let streamer {
                guard let trailer = streamer.finish() else { throw StreamCompressionFailed() }
                if !trailer.isEmpty {
                    var buffer = ByteBuffer()
                    buffer.writeBytes(trailer)
                    try await outbound.write(.body(.byteBuffer(buffer)))
                }
            }
            try await outbound.write(.end(nil))
            return
        }

        var body = response.body
        // gzip compressible bodies the client asked for (and that actually shrink).
        // A handler that set its own Content-Encoding is passed through untouched.
        if acceptsGzip, body.count >= GzipCompression.minimumBytes,
           headers.first(name: "content-encoding") == nil,
           let contentType = headers.first(name: "content-type"),
           GzipCompression.isCompressibleContentType(contentType) {
            if !headers.contains(name: "vary") { headers.add(name: "vary", value: "Accept-Encoding") }
            if let compressed = GzipCompression.gzip(body), compressed.count < body.count {
                body = compressed
                headers.add(name: "content-encoding", value: "gzip")
            }
        }
        headers.replaceOrAdd(name: "content-length", value: String(body.count))
        headers.replaceOrAdd(name: "connection", value: keepAlive ? "keep-alive" : "close")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status, reasonPhrase: response.reasonPhrase),
            headers: headers)
        try await outbound.write(.head(responseHead))
        var buffer = ByteBuffer()
        buffer.writeBytes(body)
        try await outbound.write(.body(.byteBuffer(buffer)))
        try await outbound.write(.end(nil))
    }

    private static func plumekitMethod(_ method: NIOHTTP1.HTTPMethod) -> PlumeCore.HTTPMethod? {
        switch method {
        case .GET: return .get
        case .POST: return .post
        case .PUT: return .put
        case .PATCH: return .patch
        case .DELETE: return .delete
        case .HEAD: return .head
        case .OPTIONS: return .options
        default: return nil
        }
    }

    private static func splitURI(_ uri: String) -> (String, String) {
        if let q = uri.firstIndex(of: "?") {
            return (String(uri[uri.startIndex..<q]), String(uri[uri.index(after: q)...]))
        }
        return (uri, "")
    }
}

/// A static file shrank between stat and send — the connection is failed rather than
/// sending a short body under a longer Content-Length.
struct StaticFileTruncated: Error {}

/// zlib failed mid-stream — the connection is failed rather than emitting a body
/// that no longer matches its declared Content-Encoding.
struct StreamCompressionFailed: Error {}

/// Closes a connection whose request BODY stalls: armed when a head arrives, reset
/// by every body part, disarmed at `.end`. The complement of `SlowRequestHeadTimeout`
/// (which guards the headers) — this one watches typed HTTP parts, so it can tell a
/// stalled body from a connection that is merely idle between keep-alive requests
/// or busy running the handler.
final class RequestBodyIdleTimeout: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    private let timeout: TimeAmount
    private var scheduled: Scheduled<Void>?

    init(timeout: TimeAmount) { self.timeout = timeout }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            arm(context)
        case .body:
            arm(context)   // progress — restart the clock
        case .end:
            scheduled?.cancel()
            scheduled = nil
        }
        context.fireChannelRead(data)
    }

    private func arm(_ context: ChannelHandlerContext) {
        scheduled?.cancel()
        // Capture only the Channel (Sendable); timer and reads share this event loop,
        // so a cancel always beats a concurrent fire (same shape as the head guard).
        let channel = context.channel
        scheduled = context.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        scheduled?.cancel()
        scheduled = nil
    }
}

/// Slow-loris guard, at the HEAD of the pipeline (before HTTP decoding) so it is active
/// from the moment the connection opens and survives — harmlessly, as a passthrough —
/// across a WebSocket upgrade. On connect it schedules a close; it scans the raw inbound
/// bytes for the end-of-headers terminator (`\r\n\r\n`) and cancels the close the instant
/// the request headers are complete. So any real request (normal, SSE, or a WS upgrade)
/// stops the clock before it starts streaming; only a client that never finishes its
/// headers is closed. It never buffers or rewrites data — every read is forwarded as-is.
final class SlowRequestHeadTimeout: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let timeout: TimeAmount
    private var scheduled: Scheduled<Void>?
    private var sawLF = false      // previous non-CR byte was LF (state spans reads)
    private var headersDone = false

    init(timeout: TimeAmount) { self.timeout = timeout }

    func channelActive(context: ChannelHandlerContext) {
        // Capture only the Channel (Sendable). The timer and channelRead both run on this
        // channel's event loop, so cancelling on `\r\n\r\n` always beats a concurrent fire —
        // no need to re-check state inside the timer (and nothing non-Sendable is captured).
        let channel = context.channel
        scheduled = context.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)   // no complete request head in time → slow-loris
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !headersDone {
            // Headers end at a blank line. Ignore CR and look for two consecutive LFs, so
            // this matches CR LF CR LF, a bare LF LF, and mixed endings — all of which NIO's
            // HTTP/1 decoder accepts. (A CR-only matcher would miss a bare-LF client, leaving
            // the timer armed to wrongly close its in-flight streaming response.)
            for byte in unwrapInboundIn(data).readableBytesView {
                if byte == 0x0D { continue }                // ignore CR
                if byte == 0x0A {                           // LF
                    if sawLF { headersDone = true; scheduled?.cancel(); scheduled = nil; break }
                    sawLF = true
                } else {
                    sawLF = false
                }
            }
        }
        context.fireChannelRead(data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        scheduled?.cancel()
        scheduled = nil
    }
}
