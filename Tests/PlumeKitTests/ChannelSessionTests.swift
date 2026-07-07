import Testing
import Foundation
@testable import PlumeCore
import PlumeServer

// Channel sessions: sender identity + lifecycle events, targeted pushes,
// deferred SQL effects, the event/effects wire, and token subject extraction.

/// Records every event it sees; greets openers by subject; echoes messages back
/// to ONLY the sender; queues one SQL statement per close.
private struct SessionChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {}
    func onEvent(_ event: ChannelEvent, _ context: ChannelContext) async throws {
        switch event {
        case .open(let subject):
            let n = (context.store.int("joins") ?? 0) + 1
            context.store.setInt("joins", n)
            context.push(to: subject, Array("welcome \(subject) (#\(n))".utf8))
            context.push(Array("\(subject) joined".utf8))
        case .message(let subject, let bytes):
            context.push(to: subject, Array("echo:".utf8) + bytes)
        case .close(let subject):
            context.execute("DELETE FROM online WHERE subject = ?", [.text(subject)])
        case .alarm:
            break
        }
    }
}

private actor Box {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@Test func hubDispatchesOpenCloseAndTargetsBySubject() async throws {
    let dir = "/tmp/plumekit-chantest-sessions"
    try? FileManager.default.removeItem(atPath: dir)
    let hub = ChannelHub(stateDirectory: dir) { event, context in
        try await SessionChannel().onEvent(event, context)
    }
    let alice = Box(), bob = Box()
    let aliceID = await hub.subscribe(room: "r", subject: "alice") { b in await alice.append(decodeUTF8(b)) }
    _ = await hub.subscribe(room: "r", subject: "bob") { b in await bob.append(decodeUTF8(b)) }

    // Alice got HER welcome (targeted) + both broadcasts; bob got his welcome + his join broadcast.
    #expect(await alice.values == ["welcome alice (#1)", "alice joined", "bob joined"])
    #expect(await bob.values == ["welcome bob (#2)", "bob joined"])

    // A message from bob echoes ONLY to bob.
    await hub.handle(room: "r", message: Array("hi".utf8), subject: "bob")
    #expect(await bob.values == ["welcome bob (#2)", "bob joined", "echo:hi"])
    #expect(await alice.values == ["welcome alice (#1)", "alice joined", "bob joined"])

    // Unsubscribe dispatches .close (its SQL is skipped without a database — no crash).
    await hub.unsubscribe(room: "r", id: aliceID)
    #expect(await hub.subscriberCount(room: "r") == 1)
}

@Test func hubAppliesDeferredSQLToItsDatabase() async throws {
    let dir = "/tmp/plumekit-chantest-sql"
    try? FileManager.default.removeItem(atPath: dir)
    let db = Database(try SQLiteDatabase(path: dir + ".sqlite3"))
    defer { try? FileManager.default.removeItem(atPath: dir + ".sqlite3") }
    _ = try await db.query("DROP TABLE IF EXISTS online")
    _ = try await db.query("CREATE TABLE online (subject TEXT)")
    _ = try await db.query("INSERT INTO online (subject) VALUES ('alice'), ('bob')")

    let hub = ChannelHub(stateDirectory: dir, database: db) { event, context in
        try await SessionChannel().onEvent(event, context)
    }
    let id = await hub.subscribe(room: "r", subject: "alice") { _ in }
    await hub.unsubscribe(room: "r", id: id)   // .close queues the DELETE

    let rows = try await db.query("SELECT subject FROM online")
    #expect(rows.rows.count == 1)
    if case .text(let remaining) = rows.rows[0][0] { #expect(remaining == "bob") }
}

@Test func legacyMessageHandlerStillWorksAndDropsLifecycle() async throws {
    let dir = "/tmp/plumekit-chantest-legacy"
    try? FileManager.default.removeItem(atPath: dir)
    let hub = ChannelHub(stateDirectory: dir) { message, context in
        context.push(Array("got:".utf8) + message)
    }
    let box = Box()
    _ = await hub.subscribe(room: "r") { b in await box.append(decodeUTF8(b)) }   // .open dropped
    await hub.handle(room: "r", message: Array("x".utf8))
    #expect(await box.values == ["got:x"])
}

@Test func channelEventMetaRoundTrips() {
    let meta = ChannelEventMeta(kind: 2, room: "workspace:alpha:1", subject: "client:42",
                                now: 1_751_500_000_123, entropy: 0xDEAD_BEEF_CAFE_F00D)
    let decoded = ChannelEventMeta.decode(meta.encode())
    #expect(decoded != nil)
    #expect(decoded?.kind == 2)
    #expect(decoded?.room == "workspace:alpha:1")
    #expect(decoded?.subject == "client:42")
    #expect(decoded?.now == 1_751_500_000_123)
    #expect(decoded?.entropy == 0xDEAD_BEEF_CAFE_F00D)
    if case .close(let subject) = decoded!.event(message: []) {
        #expect(subject == "client:42")
    } else {
        Issue.record("expected .close")
    }
}

@Test func channelEffectsWireRoundTrips() {
    let context = ChannelContext(store: ChannelStore(), room: "r", now: 5, entropy: 9)
    context.store.setString("k", "v")
    context.execute("UPDATE accounts SET quota = quota + ? WHERE id = ?", [.integer(10), .integer(3)])
    context.execute("DELETE FROM account_sessions WHERE account_id = ?",
                    [.null, .double(1.5), .text("t"), .blob([1, 2, 3])])
    context.push(Array("all".utf8), kind: .payload)
    context.push(to: "alice", Array("just alice".utf8), kind: .payload)
    context.broadcast(to: ChannelID("other"), [ChannelPush(kind: .fragment, bytes: Array("x".utf8))])

    let effects = decodeChannelEffects(encodeChannelEffects(context))
    #expect(effects != nil)
    #expect(effects?.writes.count == 1)
    #expect(effects?.writes.first?.key == "k")
    #expect(effects?.statements.count == 2)
    #expect(effects?.statements.first?.sql == "UPDATE accounts SET quota = quota + ? WHERE id = ?")
    if case .integer(let n) = effects!.statements[0].params[0] { #expect(n == 10) }
    if case .double(let d) = effects!.statements[1].params[1] { #expect(d == 1.5) }
    if case .text(let t) = effects!.statements[1].params[2] { #expect(t == "t") }
    if case .blob(let b) = effects!.statements[1].params[3] { #expect(b == [1, 2, 3]) }
    #expect(effects?.pushes.count == 2)
    #expect(effects?.pushes[0].subject == "")
    #expect(effects?.pushes[1].subject == "alice")
    #expect(effects?.pushes[1].bytes == Array("just alice".utf8))
    #expect(effects?.broadcasts.count == 1)
    #expect(effects?.broadcasts.first?.channel == "other")
}

/// Counts alarms; reschedules itself once (open → alarm in 50ms → alarm again once).
private struct AlarmChannel: Channel {
    init() {}
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {}
    func onEvent(_ event: ChannelEvent, _ context: ChannelContext) async throws {
        switch event {
        case .open:
            context.scheduleAlarm(atMs: context.now + 50)
        case .alarm:
            let n = (context.store.int("alarms") ?? 0) + 1
            context.store.setInt("alarms", n)
            context.push(Array("alarm \(n)".utf8))
            if n < 2 { context.scheduleAlarm(atMs: context.now + 50) }
        default:
            break
        }
    }
}

@Test func hubFiresAndReschedulesAlarms() async throws {
    let dir = "/tmp/plumekit-chantest-alarms"
    try? FileManager.default.removeItem(atPath: dir)
    let hub = ChannelHub(stateDirectory: dir) { event, context in
        try await AlarmChannel().onEvent(event, context)
    }
    let box = Box()
    _ = await hub.subscribe(room: "r", subject: "a") { b in await box.append(decodeUTF8(b)) }
    // The two alarms fire on a timer (fired, rescheduled once, then stopped). Poll rather
    // than sleep a fixed window — a loaded CI runner can be slower than the interval.
    for _ in 0..<60 {
        if await box.values == ["alarm 1", "alarm 2"] { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(await box.values == ["alarm 1", "alarm 2"])
}

@Test func alarmEffectsRoundTripOnTheWire() {
    // schedule
    let scheduling = ChannelContext(store: ChannelStore(), room: "r", now: 100, entropy: 1)
    scheduling.scheduleAlarm(atMs: 1_751_500_000_000)
    #expect(decodeChannelEffects(encodeChannelEffects(scheduling))?.alarm == 1_751_500_000_000)
    // cancel
    let cancelling = ChannelContext(store: ChannelStore(), room: "r", now: 100, entropy: 1)
    cancelling.cancelAlarm()
    #expect(decodeChannelEffects(encodeChannelEffects(cancelling))?.alarm == 0)
    // untouched
    let idle = ChannelContext(store: ChannelStore(), room: "r", now: 100, entropy: 1)
    #expect(decodeChannelEffects(encodeChannelEffects(idle))?.alarm == nil)
    // the meta kind for alarms decodes to the event
    let meta = ChannelEventMeta(kind: 3, room: "r", subject: "", now: 1, entropy: 2)
    if case .alarm = ChannelEventMeta.decode(meta.encode())!.event(message: []) {} else {
        Issue.record("expected .alarm")
    }
}

@Test func channelTokenSubjectExtraction() {
    let key = Array("secret".utf8)
    let token = ChannelToken.mint(channel: ChannelID("workspace:alpha:1"),
                                  subject: "{\"client\":7}", expiresAt: 2_000_000_000, key: key)
    #expect(ChannelToken.subject(token) == "{\"client\":7}")
    #expect(ChannelToken.verify(token, channel: ChannelID("workspace:alpha:1"),
                                now: 1_999_999_999, key: key))
    // Subject is bound into the signature — verification fails on another channel.
    #expect(!ChannelToken.verify(token, channel: ChannelID("workspace:alpha:2"),
                                 now: 1_999_999_999, key: key))
    #expect(ChannelToken.subject("garbage") == nil)
}
