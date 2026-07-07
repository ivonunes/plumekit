import Testing
@testable import PlumeCore
import PlumeServer

@Test func inProcessQueueSendsAndDrains() async throws {
    let q = InProcessQueue()
    let handle = Queue(q)
    try await handle.send("a")
    try await handle.send(Array("b".utf8))
    let drained = await q.drain()
    #expect(drained.count == 2)
    #expect(PlumeCore.decodeUTF8(drained[0]) == "a")
    #expect(PlumeCore.decodeUTF8(drained[1]) == "b")
    #expect(await q.messages.isEmpty)
}
