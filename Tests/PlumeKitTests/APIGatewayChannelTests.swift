import Testing
import Foundation
@testable import PlumeCore
@testable import PlumeAWS

// In-memory stand-ins for the API Gateway platform ports (DynamoDB state +
// connection store, postToConnection), so the adapter runs offline. Production
// swaps these for real AWS calls; the adapter + the Channel protocol are identical.
private actor MemPlatform {
    var state: [String: [(key: String, value: [UInt8])]] = [:]
    var conns: [String: [ChannelConnection]] = [:]
    var posted: [(conn: String, text: String)] = []

    func load(_ c: String) -> [(key: String, value: [UInt8])] { state[c] ?? [] }
    func save(_ c: String, _ s: [(key: String, value: [UInt8])]) { state[c] = s }
    func connections(_ c: String) -> [ChannelConnection] { conns[c] ?? [] }
    func connect(_ c: String, _ conn: ChannelConnection) { conns[c, default: []].append(conn) }
    func post(_ id: String, _ bytes: [UInt8]) { posted.append((id, decodeUTF8(bytes))) }
    func postedTo(_ id: String) -> [String] { posted.filter { $0.conn == id }.map { $0.text } }
}

// A representative app channel — the SAME shape as the example RoomChannel.
private struct CountChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        let n = (context.store.int("count") ?? 0) + 1
        context.store.setInt("count", n)
        context.push(Array("<li>msg#\(n)</li>".utf8), kind: .fragment)
        context.push(Array("{\"n\":\(n)}".utf8), kind: .payload)
    }
}

private func makeHandler(_ mem: MemPlatform) -> APIGatewayChannelHandler {
    let ports = APIGatewayChannelPorts(
        loadState: { await mem.load($0) },
        saveState: { await mem.save($0, $1) },
        connections: { await mem.connections($0) },
        post: { await mem.post($0, $1) })
    return APIGatewayChannelHandler(ports: ports) { message, context in
        try await CountChannel().onMessage(message, context)
    }
}

@Test func apiGatewayChannelDrivesTheProtocolUnchanged() async {
    let mem = MemPlatform()
    let agw = makeHandler(mem)

    // Two subscribers of different kinds (the DynamoDB connection store).
    await mem.connect("room1", ChannelConnection(connectionID: "A", kind: .fragment))
    await mem.connect("room1", ChannelConnection(connectionID: "B", kind: .payload))

    // Two per-message Lambda invocations — state is REBUILT from the external store
    // each time (no in-process actor, like the DO).
    await agw.onMessage(channel: "room1", message: Array("hi".utf8))
    await agw.onMessage(channel: "room1", message: Array("hi".utf8))

    #expect(await mem.postedTo("A") == ["<li>msg#1</li>", "<li>msg#2</li>"])   // fragment kind only
    #expect(await mem.postedTo("B") == ["{\"n\":1}", "{\"n\":2}"])             // payload kind only
}

@Test func apiGatewayBroadcastFansOutByKind() async {
    let mem = MemPlatform()
    let agw = makeHandler(mem)
    await mem.connect("posts", ChannelConnection(connectionID: "web", kind: .fragment))
    await mem.connect("posts", ChannelConnection(connectionID: "ios", kind: .payload))

    // Out-of-request broadcast (model change / job) through the SAME adapter.
    await agw.broadcast(channel: "posts", pushes: [
        ChannelPush(kind: .fragment, bytes: Array("<li>new</li>".utf8)),
        ChannelPush(kind: .payload, bytes: Array("{\"id\":1}".utf8)),
    ])
    #expect(await mem.postedTo("web") == ["<li>new</li>"])
    #expect(await mem.postedTo("ios") == ["{\"id\":1}"])
}

@Test func apiGatewaySignedSubscriptionEnforced() {
    let mem = MemPlatform()
    let agw = makeHandler(mem)
    let key = Array("signing-key".utf8)
    let token = ChannelToken.mint(channel: ChannelID("room1"), subject: "u", expiresAt: 2_000_000, key: key)

    #expect(agw.authorize(channel: "room1", token: token, now: 1_000_000, key: key))      // valid
    #expect(!agw.authorize(channel: "room2", token: token, now: 1_000_000, key: key))     // wrong channel
    #expect(!agw.authorize(channel: "room1", token: token + "ff", now: 1_000_000, key: key)) // forged
    #expect(!agw.authorize(channel: "room1", token: token, now: 3_000_000, key: key))     // expired
}

private struct DMChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        context.push(to: "user-42", Array("secret".utf8))   // targeted at one subject
        context.push(Array("broadcast".utf8))               // to everyone (empty subject)
    }
}

@Test func apiGatewayChannelTargetsPushBySubject() async {
    let mem = MemPlatform()
    let ports = APIGatewayChannelPorts(
        loadState: { await mem.load($0) }, saveState: { await mem.save($0, $1) },
        connections: { await mem.connections($0) }, post: { await mem.post($0, $1) })
    let agw = APIGatewayChannelHandler(ports: ports) { m, c in try await DMChannel().onMessage(m, c) }
    // Same kind, different subjects — the targeted push must not leak to user-99.
    await mem.connect("room", ChannelConnection(connectionID: "A", kind: .fragment, subject: "user-42"))
    await mem.connect("room", ChannelConnection(connectionID: "B", kind: .fragment, subject: "user-99"))
    await agw.onMessage(channel: "room", message: Array("hi".utf8))
    #expect(await mem.postedTo("A") == ["secret", "broadcast"])
    #expect(await mem.postedTo("B") == ["broadcast"])
}
