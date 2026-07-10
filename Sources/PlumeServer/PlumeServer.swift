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
        // exists. Resolved once to an absolute path so per-request lookups can't be fooled
        // by a changing working directory.
        let publicRoot: String? = {
            let dir = publicDirectory ?? "Public"
            let absolute = dir.hasPrefix("/") ? dir : FileManager.default.currentDirectoryPath + "/" + dir
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? absolute : nil
        }()
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
            var body = ByteBuffer()
            var oversized = false
            var sse: (room: String, id: Int)?
            for try await part in inbound {
                switch part {
                case .head(let h):
                    head = h
                    body.clear()
                    oversized = false
                case .body(var chunk):
                    // Cap the buffered body so a huge (or lying `Content-Length`) upload
                    // can't OOM the server. Once over, answer 413 and stop buffering.
                    if oversized { break }
                    if body.readableBytes + chunk.readableBytes > Self.maxRequestBodyBytes {
                        oversized = true
                        body.clear()
                        try await write(Response.text("413 Payload Too Large", status: 413), to: outbound)
                        head = nil
                        break
                    }
                    body.writeBuffer(&chunk)
                case .end:
                    if oversized { oversized = false; head = nil; break }   // already answered 413
                    guard let h = head else { break }
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
                                try await write(Response.text("403 Forbidden", status: 403), to: outbound)
                                head = nil
                                continue
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
                    } else {
                        let response = await respond(head: h, body: body, app: app,
                                                     context: context, publicRoot: publicRoot)
                        try await write(response, to: outbound)
                        head = nil
                    }
                }
            }
            if let sse { await channels?.unsubscribe(room: sse.room, id: sse.id) }
        }
    }

    private static func pathComponent(_ uri: String) -> String {
        if let q = uri.firstIndex(of: "?") { return String(uri[uri.startIndex..<q]) }
        return uri
    }

    private static func respond(
        head: HTTPRequestHead,
        body: ByteBuffer,
        app: Application,
        context: Context,
        publicRoot: String?
    ) async -> Response {
        guard let method = plumekitMethod(head.method) else {
            return Response.text("405 Method Not Allowed", status: 405)
        }
        let (path, query) = splitURI(head.uri)

        // Static files take priority for GET/HEAD; a miss falls through to the app's routes.
        if method == .get || method == .head, let publicRoot,
           let file = StaticFiles.response(for: path, in: publicRoot) {
            if method == .head { var headOnly = file; headOnly.body = []; return headOnly }
            return file
        }
        var headers = Headers()
        for field in head.headers { headers.add(field.name, field.value) }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        let request = Request(method: method, path: path, query: query,
                              headers: headers, body: bytes, context: context)
        do {
            return try await app.handleThrowing(request)
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
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        var headers = HTTPHeaders()
        // Strip CR/LF/NUL from every header value so an attacker-influenced value (e.g. a
        // redirect Location or cookie built from user input) can't inject headers or split
        // the response. Defense-in-depth — the app should validate too, but the wire must be safe.
        for field in response.headers.fields {
            headers.add(name: field.name, value: field.value.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
        }
        headers.replaceOrAdd(name: "content-length", value: String(response.body.count))
        headers.replaceOrAdd(name: "connection", value: "close")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.status, reasonPhrase: response.reasonPhrase),
            headers: headers)
        try await outbound.write(.head(responseHead))
        var buffer = ByteBuffer()
        buffer.writeBytes(response.body)
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
