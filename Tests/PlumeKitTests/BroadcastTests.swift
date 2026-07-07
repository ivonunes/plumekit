import Testing
import Foundation
@testable import PlumeCore
import PlumeServer

private actor Sink {
    var values: [String] = []
    func append(_ v: String) { values.append(v) }
}

private actor Captured {
    var channel = ""
    var kinds: [PayloadKind] = []
    func record(_ channel: String, _ pushes: [ChannelPush]) {
        self.channel = channel
        self.kinds = pushes.map { $0.kind }
    }
}

private struct Item: Broadcastable {
    let id: Int
    static func broadcastChannel(for m: Item) -> ChannelID { ChannelID("items") }
    static func broadcastPushes(for m: Item) -> [ChannelPush] {
        [ChannelPush(kind: .fragment, bytes: Array("<li>\(m.id)</li>".utf8)),
         ChannelPush(kind: .payload, bytes: Array("{\"id\":\(m.id)}".utf8))]
    }
}

@Test func channelTokenAcceptsValidRejectsForgedExpiredWrongChannel() {
    let key = Array("test-signing-key".utf8)
    let now = 1_000_000
    let token = ChannelToken.mint(channel: ChannelID("room:1"), subject: "u1", expiresAt: now + 100, key: key)

    #expect(ChannelToken.verify(token, channel: ChannelID("room:1"), now: now, key: key))           // valid
    #expect(!ChannelToken.verify(token, channel: ChannelID("room:1"), now: now + 200, key: key))     // expired
    #expect(!ChannelToken.verify(token, channel: ChannelID("room:2"), now: now, key: key))           // wrong channel
    #expect(!ChannelToken.verify(token, channel: ChannelID("room:1"), now: now, key: Array("other".utf8))) // wrong key
    let forged = String(token.dropLast(4)) + "0000"
    #expect(!ChannelToken.verify(forged, channel: ChannelID("room:1"), now: now, key: key))          // forged sig
    #expect(!ChannelToken.verify("garbage", channel: ChannelID("room:1"), now: now, key: key))       // malformed
    #expect(!ChannelToken.verify("", channel: ChannelID("room:1"), now: now, key: key))              // empty
}

@Test func broadcastFansModelOutThroughBroadcaster() async {
    let captured = Captured()
    let broadcaster = Broadcaster { channel, pushes in await captured.record(channel.value, pushes) }
    await broadcast(Item(id: 7), via: broadcaster)
    #expect(await captured.channel == "items")
    #expect(await captured.kinds == [.fragment, .payload])
}

@Test func hubBroadcastDeliversToMatchingKindOnly() async {
    let dir = "/tmp/plumekit-bctest-kind"
    try? FileManager.default.removeItem(atPath: dir)
    let hub = ChannelHub(stateDirectory: dir) { _, _ in }
    let fragments = Sink(), payloads = Sink()
    _ = await hub.subscribe(room: "r", kind: .fragment) { b in await fragments.append(decodeUTF8(b)) }
    _ = await hub.subscribe(room: "r", kind: .payload) { b in await payloads.append(decodeUTF8(b)) }

    await hub.broadcast("r", [
        ChannelPush(kind: .fragment, bytes: Array("FRAG".utf8)),
        ChannelPush(kind: .payload, bytes: Array("PAYLOAD".utf8)),
    ])
    #expect(await fragments.values == ["FRAG"])     // each kind only to its subscribers
    #expect(await payloads.values == ["PAYLOAD"])
}

@Test func channelContextRecordsCrossChannelBroadcasts() {
    let context = ChannelContext(store: ChannelStore())
    context.push(Array("self".utf8), kind: .fragment)
    context.broadcast(to: ChannelID("other"), [ChannelPush(kind: .fragment, bytes: Array("x".utf8))])
    #expect(context.pushes.count == 1)
    #expect(context.broadcasts.count == 1)
    #expect(context.broadcasts[0].channel.value == "other")
}
