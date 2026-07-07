import _Concurrency

// Scheduled tasks — "run this every N minutes / hourly / daily", the same code on
// every target. A schedule is a list of named tasks with a cadence; a once-a-minute
// TICK drives it, and due-ness is matched statelessly against the wall clock (UTC),
// cron-style. Who ticks differs per platform, the schedule doesn't:
//
//   • native — `PlumeServer.run` ticks on minute boundaries;
//   • Cloudflare — a Cron Trigger (`crons = ["* * * * *"]`) invokes the worker's
//     `scheduled` handler, which forwards a tick envelope to the job dispatcher;
//   • AWS — an EventBridge 1-minute rule does the same through the queue.
//
//     public func buildSchedule() -> Schedule {
//         var schedule = Schedule()
//         schedule.task("prune-sessions", every: .hourly()) { context in
//             _ = try await context.database?.query("DELETE FROM sessions WHERE …")
//         }
//         schedule.task("daily-digest", every: .daily(hour: 6)) { context in … }
//         return schedule
//     }
//
// Tasks run at most once per matching minute; a missed tick (asleep laptop, cold
// worker) is skipped, not replayed — cron semantics, not a durable job queue. For
// work that must not be lost, have the task enqueue a Job.

/// How often a scheduled task runs. All times are UTC.
public enum Every: Sendable {
    case minute
    /// Every `n` minutes, counted from the Unix epoch. For divisors of 60
    /// (`.minutes(15)`) that lands on :00 :15 :30 :45; other values keep a strict
    /// every-n rhythm across hour boundaries rather than snapping to them.
    case minutes(Int)
    /// Once an hour, at the given minute.
    case hourly(atMinute: Int = 0)
    /// Once a day, at the given hour/minute (UTC).
    case daily(hour: Int, minute: Int = 0)

    /// Whether a tick at `epochSeconds` matches this cadence. Pure integer math on
    /// the epoch (UTC) — no calendar library, Embedded-clean.
    public func isDue(atEpochSeconds epoch: Int64) -> Bool {
        let totalMinutes = epoch / 60
        let minuteOfHour = Int(totalMinutes % 60)
        let hourOfDay = Int((totalMinutes / 60) % 24)
        switch self {
        case .minute:
            return true
        case .minutes(let n):
            return n > 0 && totalMinutes % Int64(n) == 0
        case .hourly(let atMinute):
            return minuteOfHour == atMinute
        case .daily(let hour, let minute):
            return hourOfDay == hour && minuteOfHour == minute
        }
    }
}

/// The app's scheduled tasks. Build one in `buildSchedule()`; the platform wiring
/// ticks it once a minute.
public struct Schedule: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let every: Every
        public let run: @Sendable (Context) async throws -> Void
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Register a task. `name` identifies it in logs; keep it stable.
    public mutating func task(_ name: String, every: Every,
                              _ run: @escaping @Sendable (Context) async throws -> Void) {
        // Catch impossible cadences at registration, not silently at runtime.
        switch every {
        case .minutes(let n):
            precondition(n > 0, "schedule task '\(name)': .minutes(\(n)) never fires")
        case .hourly(let minute):
            precondition((0...59).contains(minute), "schedule task '\(name)': minute \(minute) is out of range")
        case .daily(let hour, let minute):
            precondition((0...23).contains(hour) && (0...59).contains(minute),
                         "schedule task '\(name)': \(hour):\(minute) is out of range")
        case .minute:
            break
        }
        entries.append(Entry(name: name, every: every, run: run))
    }

    /// Run every task whose cadence matches this tick. Failures are logged and don't
    /// stop the other tasks (matching cron: one bad task never blocks the rest).
    public func runDue(atEpochSeconds epoch: Int64, context: Context) async {
        for entry in entries where entry.every.isDue(atEpochSeconds: epoch) {
            do {
                try await entry.run(context)
            } catch {
                context.log("Scheduled task '\(entry.name)' failed")
            }
        }
    }

    /// The reserved job name whose envelope drives the schedule on queue-backed
    /// targets (the Cloudflare `scheduled` handler and EventBridge forward this).
    public static let tickJobName = "plumekit.schedule.tick"

    /// A tick envelope for the job dispatcher. The payload is the tick's epoch
    /// seconds as ASCII decimal — the sender's clock, so the guest needs none.
    public static func tickEnvelope(epochSeconds: Int64) -> [UInt8] {
        encodeJobEnvelope(tickJobName, Array(String(epochSeconds).utf8))
    }
}

extension JobRegistry {
    /// Fold a schedule into the registry: a `plumekit.schedule.tick` envelope runs
    /// every due task. This is how queue-backed targets (Cloudflare Cron Triggers,
    /// EventBridge) drive the schedule through the existing job path.
    public mutating func include(_ schedule: Schedule) {
        register(name: Schedule.tickJobName) { payload, context in
            // The payload is the tick time (ASCII decimal epoch seconds). Strict,
            // overflow-safe parse: a malformed envelope is skipped, never a crash.
            var epoch: Int64 = 0
            var valid = !payload.isEmpty
            for byte in payload {
                guard byte >= 0x30, byte <= 0x39 else { valid = false; break }
                let (shifted, overflow1) = epoch.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = shifted.addingReportingOverflow(Int64(byte - 0x30))
                if overflow1 || overflow2 { valid = false; break }
                epoch = sum
            }
            if !valid { epoch = 0 }
            guard epoch > 0 else {
                context.log("schedule tick without a timestamp — skipped")
                return
            }
            await schedule.runDue(atEpochSeconds: epoch, context: context)
        }
    }
}
