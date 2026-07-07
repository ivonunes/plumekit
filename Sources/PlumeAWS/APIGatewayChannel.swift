import Foundation
import PlumeCore

// The THIRD `Channel` implementation — API Gateway WebSockets. This is the
// real portability test of the `Channel` protocol: API Gateway holds the socket and
// invokes Lambda PER MESSAGE (run-to-completion), with connection ids + channel
// state persisted EXTERNALLY (DynamoDB), and fan-out via the API Gateway Management
// API `postToConnection`. A completely different runtime from the Durable Object
// and the native actor.
//
// The `Channel` protocol fits UNCHANGED. The DO and native adapters
// forced the right shape — a synchronous handler over a PRE-LOADED store whose
// effects the adapter applies — precisely because async store access was impossible
// in a DO. API Gateway is a third instance of that exact shape: load state → run
// the handler → persist writes + fan out pushes. The protocol named no platform
// primitive, so nothing here required changing `Channel`, `ChannelContext`,
// `ChannelStore`, `ChannelPush`, or `ChannelToken`.
//
// The platform specifics are injected as PORTS (DynamoDB + postToConnection), so
// the same adapter is driven by real AWS services in production and by an in-memory
// harness in tests. NOTHING below is platform-conditional in the core.

/// A subscriber as the connection store records it. `subject` is the connection's
/// verified identity (recorded at `$connect`), so a targeted `push(to:)` reaches only
/// that subscriber instead of every connection of the kind.
public struct ChannelConnection: Sendable {
    public let connectionID: String
    public let kind: PayloadKind
    public let subject: String
    public init(connectionID: String, kind: PayloadKind, subject: String = "") {
        self.connectionID = connectionID
        self.kind = kind
        self.subject = subject
    }
}

/// The ports the API Gateway adapter needs from the platform. In production these
/// are DynamoDB (state + connections) and the API Gateway Management API
/// (postToConnection); in tests they're in-memory. None leaks into `Channel`.
public struct APIGatewayChannelPorts: Sendable {
    public var loadState: @Sendable (String) async -> [(key: String, value: [UInt8])]
    public var saveState: @Sendable (String, [(key: String, value: [UInt8])]) async -> Void
    public var connections: @Sendable (String) async -> [ChannelConnection]
    public var post: @Sendable (String, [UInt8]) async -> Void   // connectionID, bytes

    public init(
        loadState: @escaping @Sendable (String) async -> [(key: String, value: [UInt8])],
        saveState: @escaping @Sendable (String, [(key: String, value: [UInt8])]) async -> Void,
        connections: @escaping @Sendable (String) async -> [ChannelConnection],
        post: @escaping @Sendable (String, [UInt8]) async -> Void
    ) {
        self.loadState = loadState
        self.saveState = saveState
        self.connections = connections
        self.post = post
    }
}

/// Drives an app `Channel` over API Gateway WebSockets. Each method is one Lambda
/// invocation (API Gateway route): `$connect` verifies the signed subscription;
/// `$default` runs the channel handler per message; `broadcast` originates an
/// out-of-request fan-out (model change / job).
public struct APIGatewayChannelHandler: Sendable {
    let ports: APIGatewayChannelPorts
    let handler: @Sendable ([UInt8], ChannelContext) async throws -> Void

    public init(
        ports: APIGatewayChannelPorts,
        handler: @escaping @Sendable ([UInt8], ChannelContext) async throws -> Void
    ) {
        self.ports = ports
        self.handler = handler
    }

    /// `$connect` route: a subscribe must present a valid channel-scoped token.
    public func authorize(channel: String, token: String, now: Int, key: [UInt8]) -> Bool {
        ChannelToken.verify(token, channel: ChannelID(channel), now: now, key: key)
    }

    /// `$default` route: handle one message run-to-completion — load state, run the
    /// SAME `Channel` handler, persist writes, fan out pushes (by kind) + any
    /// cross-channel broadcasts. Identical shape to the DO + native hub.
    public func onMessage(channel: String, message: [UInt8], now: Int64 = 0, entropy: UInt64 = 0) async {
        let store = ChannelStore(await ports.loadState(channel))
        let context = ChannelContext(store: store, room: channel, now: now, entropy: entropy)
        try? await handler(message, context)
        if !store.writes.isEmpty { await ports.saveState(channel, store.snapshot) }
        await deliver(channel, context.pushes)
        for entry in context.broadcasts { await deliver(entry.channel.value, entry.pushes) }
    }

    /// Originate a broadcast to a channel's subscribers (model change / job).
    public func broadcast(channel: String, pushes: [ChannelPush]) async {
        await deliver(channel, pushes)
    }

    private func deliver(_ channel: String, _ pushes: [ChannelPush]) async {
        let subs = await ports.connections(channel)
        for push in pushes {
            // A push with a subject is targeted — deliver only to matching connections
            // (mirrors the Durable Object); an empty subject broadcasts to the kind.
            for sub in subs
            where sub.kind == push.kind && (push.subject.isEmpty || sub.subject == push.subject) {
                await ports.post(sub.connectionID, push.bytes)
            }
        }
    }
}
