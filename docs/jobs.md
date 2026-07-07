# Background jobs

Typed background jobs: enqueue via the Queue *producer*, run by a *consumer*.
The same job code runs on both adapter sets: a Cloudflare **queue consumer** on
the edge, and a native **drainer** in `plumekit serve`.

## Defining and enqueueing a job

```swift
struct LogJob: Job {
    static let name = "log"
    let message: String
    init(message: String) { self.message = message }
    init(payload: [UInt8]) { self.message = decodeUTF8(payload) }   // deserialize
    func payload() -> [UInt8] { encodeUTF8(message) }                // serialize
    func perform(_ context: Context) async throws {                 // the work
        await context.kv?.putString("last-job", message)            // jobs reach bindings
    }
}

// enqueue (in a handler):
try await LogJob(message: "hi").enqueue(on: request.bindings.queue)
```

A job serializes its args to `[UInt8]`, reconstructs from them, and `perform`s with
a `Context`. Inside `perform`, capabilities are ambient too (`Post.save()`,
`KV.current`), the same as a handler. `enqueue` wraps the job in a wire envelope
(`[u16 nameLen][name][payload]`) and sends it on the queue.

## Dispatch — jobs are auto-registered

You don't wire jobs up by hand. **Every type conforming to `Job` under
`Sources/App/Jobs/` is discovered at build time and registered** — any depth, so
organize them into subfolders (`Jobs/Email/`, `Jobs/Billing/`) freely; order is
irrelevant because jobs dispatch by name. Drop a file in and it runs.

The consumer calls a generated `buildJobs()` (under `Sources/App/Generated/`, never
hand-edited) that registers every discovered job and wires the schedule's tick in.
Scaffold one with `plumekit generate job SendEmail` → it writes
`Sources/App/Jobs/SendEmailJob.swift`, registered on the next build. Two jobs sharing
a `static var name` fail the build (they'd collide on dispatch).

The registry holds concrete closures (`([UInt8], Context) async throws -> Void`);
`register<J: Job>` captures each type statically.

## Consumers on both targets

- **Native**: `PlumeServer.run(..., jobs: buildJobs())` spawns a background loop
  that drains the in-process queue and dispatches each message. `plumekit serve` runs
  it automatically.
- **Cloudflare**: a wasm export `plumekit_queue` (alongside `plumekit_handle`)
  dispatches one message; `worker.mjs`'s `queue(batch, env)` handler delivers each
  message from `batch.messages` to it (JSPI-suspendable, so `perform` can `await`
  host calls). Wired by a `[[queues.consumers]]` binding in `wrangler.toml`.

Two Cloudflare-specific details:
- a `MessageBatch` is **not** iterable; iterate `batch.messages`;
- queue bodies must be sent with `contentType: "bytes"` to round-trip raw bytes
  (the consumer receives an `ArrayBuffer`).


## Scheduled tasks

Recurring work ("run this every N minutes / hourly / daily") rides the same core.
Unlike jobs, schedules are **declared by hand in one place** — `registerSchedules(_
schedule: inout Schedule)` in `Sources/App/Schedules.swift` (its own file, like
`Routes.swift`):

```swift
func registerSchedules(_ schedule: inout Schedule) {
    schedule.task("prune", every: .hourly()) { context in
        _ = try await context.database?.query("DELETE FROM sessions WHERE …")
    }
    // For durable work, enqueue a (discovered) Job instead of running inline:
    schedule.task("daily-digest", every: .daily(hour: 6)) { context in
        try await SendDigest().enqueue(on: context.queue)
    }
}
```

Cadences: `.minute`, `.minutes(n)`, `.hourly(atMinute:)`, `.daily(hour:minute:)`,
all **UTC**. Due-ness is matched statelessly against the wall clock (cron
semantics: a missed tick is **skipped**, not replayed; for must-not-lose work,
have the task enqueue a Job). A failing task is logged and doesn't block the other
tasks.

Only the ticker differs per target; the schedule doesn't:

- **Native**: `PlumeServer.run` ticks the schedule on minute boundaries;
  `plumekit serve` runs it automatically.
- **Cloudflare**: a Cron Trigger in `wrangler.toml`:

  ```toml
  [triggers]
  crons = ["* * * * *"]
  ```

  **One** every-minute cron drives all tasks: the worker's `scheduled` handler
  forwards a tick envelope through the job path above.
- **AWS**: an EventBridge 1-minute rule sends the same envelope through the queue.

The plumbing is generated: `buildSchedule()` wraps your `registerSchedules`, and the
generated `buildJobs()` does `registry.include(buildSchedule())` — so the schedule's
tick is a registered job on the queue-backed targets, while `PlumeServer.run(schedule:)`
also ticks it natively. You only write `registerSchedules`.
