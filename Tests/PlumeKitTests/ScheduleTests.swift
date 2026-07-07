import Testing
import PlumeCore

@Suite struct ScheduleTests {
    // 2026-01-01 00:00:00 UTC — a known minute boundary (midnight).
    private let midnight: Int64 = 1_767_225_600

    @Test func cadenceMatching() {
        #expect(Every.minute.isDue(atEpochSeconds: midnight))
        #expect(Every.minute.isDue(atEpochSeconds: midnight + 60))

        // every 15 minutes: :00, :15, :30, :45
        #expect(Every.minutes(15).isDue(atEpochSeconds: midnight))
        #expect(!Every.minutes(15).isDue(atEpochSeconds: midnight + 60))
        #expect(Every.minutes(15).isDue(atEpochSeconds: midnight + 15 * 60))

        // hourly at :30
        #expect(Every.hourly(atMinute: 30).isDue(atEpochSeconds: midnight + 30 * 60))
        #expect(!Every.hourly(atMinute: 30).isDue(atEpochSeconds: midnight))

        // daily at 06:00 UTC
        #expect(Every.daily(hour: 6).isDue(atEpochSeconds: midnight + 6 * 3600))
        #expect(!Every.daily(hour: 6).isDue(atEpochSeconds: midnight + 7 * 3600))
        #expect(!Every.daily(hour: 6).isDue(atEpochSeconds: midnight + 6 * 3600 + 60))
    }

    @Test func runDueExecutesOnlyMatchingTasksAndIsolatesFailures() async {
        struct Boom: Error {}
        final class Counter: @unchecked Sendable { var hits: [String] = [] }
        let counter = Counter()

        var schedule = Schedule()
        schedule.task("always", every: .minute) { _ in counter.hits.append("always") }
        schedule.task("exploding", every: .minute) { _ in throw Boom() }
        schedule.task("after-failure", every: .minute) { _ in counter.hits.append("after-failure") }
        schedule.task("daily", every: .daily(hour: 6)) { _ in counter.hits.append("daily") }

        await schedule.runDue(atEpochSeconds: midnight, context: .empty)

        #expect(counter.hits == ["always", "after-failure"])   // daily not due; failure isolated
    }

    @Test func tickEnvelopeDrivesTheScheduleThroughTheJobRegistry() async throws {
        final class Counter: @unchecked Sendable { var hits = 0 }
        let counter = Counter()

        var schedule = Schedule()
        schedule.task("quarterly", every: .minutes(15)) { _ in counter.hits += 1 }
        var registry = JobRegistry()
        registry.include(schedule)

        // A due tick runs the task; a non-due tick doesn't; garbage is skipped.
        #expect(try await registry.dispatch(Schedule.tickEnvelope(epochSeconds: midnight), .empty))
        #expect(counter.hits == 1)
        #expect(try await registry.dispatch(Schedule.tickEnvelope(epochSeconds: midnight + 60), .empty))
        #expect(counter.hits == 1)
        #expect(try await registry.dispatch(encodeJobEnvelope("plumekit.schedule.tick", []), .empty))
        #expect(counter.hits == 1)   // no timestamp → skipped, not crashed
    }
}
