import Testing
import Foundation
@testable import PlumeCore
import PlumeServer

private struct CounterChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        let n = (context.store.int("n") ?? 0) + 1
        context.store.setInt("n", n)
        context.push(Array("n=\(n)".utf8))
    }
}

private actor Box {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@Test func channelStoreReadsWritesAndTracksWrites() {
    let store = ChannelStore([(key: "n", value: Array("5".utf8))])
    #expect(store.int("n") == 5)
    store.setInt("n", 6)
    #expect(store.int("n") == 6)
    #expect(store.writes.count == 1)
    #expect(store.snapshot.contains { $0.key == "n" })
}

@Test func channelStoreEmptyValueDeletesTheKey() {
    let store = ChannelStore([(key: "a", value: Array("1".utf8)),
                              (key: "b", value: Array("2".utf8))])
    store.set("a", [])                                  // empty = delete
    #expect(store.get("a") == nil)                      // gone from reads…
    #expect(!store.snapshot.contains { $0.key == "a" }) // …and from the snapshot
    #expect(store.list(prefix: "a").isEmpty)
    #expect(store.get("b") != nil)                      // neighbours untouched
    // The delete is still RECORDED, so adapters can erase durable storage.
    #expect(store.writes.contains { $0.key == "a" && $0.value.isEmpty })
    store.delete("b")                                   // the named spelling
    #expect(store.get("b") == nil)
    #expect(store.snapshot.isEmpty)
}

@Test func channelHubFansOutToAllSubscribers() async throws {
    let dir = "/tmp/plumekit-chantest-fanout"
    try? FileManager.default.removeItem(atPath: dir)
    let hub = ChannelHub(stateDirectory: dir) { message, context in
        try await CounterChannel().onMessage(message, context)
    }
    let boxA = Box(), boxB = Box()
    _ = await hub.subscribe(room: "r") { bytes in await boxA.append(decodeUTF8(bytes)) }
    _ = await hub.subscribe(room: "r") { bytes in await boxB.append(decodeUTF8(bytes)) }

    await hub.handle(room: "r", message: Array("hi".utf8))
    #expect(await boxA.values == ["n=1"])     // both subscribers got the push
    #expect(await boxB.values == ["n=1"])

    // A different room is a separate shard (independent state).
    let boxC = Box()
    _ = await hub.subscribe(room: "other") { bytes in await boxC.append(decodeUTF8(bytes)) }
    await hub.handle(room: "other", message: Array("hi".utf8))
    #expect(await boxC.values == ["n=1"])
}

@Test func channelHubRestoresStateFromDisk() async throws {
    let dir = "/tmp/plumekit-chantest-restore"
    try? FileManager.default.removeItem(atPath: dir)
    let make = { ChannelHub(stateDirectory: dir) { m, c in try await CounterChannel().onMessage(m, c) } }

    let hub1 = make()
    await hub1.handle(room: "r", message: Array("a".utf8))   // n=1, persisted

    // A fresh hub (simulating a process restart) continues from disk.
    let hub2 = make()
    let box = Box()
    _ = await hub2.subscribe(room: "r") { bytes in await box.append(decodeUTF8(bytes)) }
    await hub2.handle(room: "r", message: Array("b".utf8))
    #expect(await box.values == ["n=2"])     // restored count, not n=1
}

/// Reports the PRIOR value of a durable and a volatile "~" key, then overwrites
/// both with the incoming message — so each push shows what survived.
private struct EchoStoreChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        let d = context.store.get("durable").map { decodeUTF8($0) } ?? "-"
        let v = context.store.get("~hot").map { decodeUTF8($0) } ?? "-"
        context.store.set("durable", message)
        context.store.set("~hot", message)
        context.push(Array("d=\(d) v=\(v)".utf8))
    }
}

@Test func volatileKeysLiveInMemoryButNeverReachDisk() async throws {
    let dir = "/tmp/plumekit-chantest-volatile"
    try? FileManager.default.removeItem(atPath: dir)
    let make = { ChannelHub(stateDirectory: dir) { m, c in try await EchoStoreChannel().onMessage(m, c) } }

    let hub1 = make()
    let box1 = Box()
    _ = await hub1.subscribe(room: "r") { bytes in await box1.append(decodeUTF8(bytes)) }
    await hub1.handle(room: "r", message: Array("x".utf8))
    await hub1.handle(room: "r", message: Array("x2".utf8))
    // Within the process both tiers survive between dispatches (the room cache).
    #expect(await box1.values == ["d=- v=-", "d=x v=x"])

    // A restart keeps the durable key and loses the volatile one — the "~"
    // tier is respawnable state and must never be written to disk.
    let hub2 = make()
    let box2 = Box()
    _ = await hub2.subscribe(room: "r") { bytes in await box2.append(decodeUTF8(bytes)) }
    await hub2.handle(room: "r", message: Array("y".utf8))
    #expect(await box2.values == ["d=x2 v=-"])
    let text = String(decoding: FileManager.default.contents(atPath: dir + "/r.kv") ?? Data(), as: UTF8.self)
    #expect(text.contains("durable"))
    #expect(!text.contains("~hot"))
}
