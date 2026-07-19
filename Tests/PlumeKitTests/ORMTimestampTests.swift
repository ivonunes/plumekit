import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// Auto-managed createdAt/updatedAt: a model opts in by declaring the
// fields; @Model sets them from ORMClock on save (createdAt on INSERT, updatedAt
// on every save).
@Model
final class Event: Model {
    var id: Int
    var name: String
    var createdAt: Int64 = 0
    var updatedAt: Int64 = 0
}

// Tests that mutate the process-global ORMClock share ONE serialized suite, so a
// parallel test can't clobber the clock mid-test (Swift Testing runs tests in
// parallel by default). Clock-dependent tests in other files join this suite via
// `extension SerializedClockTests`.
@Suite(.serialized)
struct SerializedClockTests {}

extension SerializedClockTests {
@Test func autoManagedTimestamps() async throws {
    ORMClock.now = { 1000 }
    defer { ORMClock.now = { 0 } }

    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Event.createTable(in: db)

    let event = Event(name: "x")
    #expect(event.createdAt == 0)            // not yet saved
    _ = try await event.save(in: db)             // INSERT
    #expect(event.createdAt == 1000)
    #expect(event.updatedAt == 1000)

    ORMClock.now = { 2000 }
    event.name = "y"
    _ = try await event.save(in: db)             // UPDATE bumps updatedAt only
    let reloaded = try await Event.find(event.id, in: db)
    #expect(reloaded?.createdAt == 1000)     // stable
    #expect(reloaded?.updatedAt == 2000)     // bumped
}
}
