# Background jobs

Some work does not belong in a request: sending email, crunching data, anything slow. A background job is a typed unit of work you enqueue from a handler and run later on a consumer. The same job code runs on both adapter sets: a native drainer inside `plumekit serve` and a Cloudflare queue consumer on the edge.

## Defining a job

A job conforms to `Job`: it serialises its arguments to `[UInt8]`, reconstructs itself from them and does the work in `perform` with a `Context`:

```swift
struct LogJob: Job {
    static let name = "log"
    let message: String
    init(message: String) { self.message = message }
    init(payload: [UInt8]) { self.message = decodeUTF8(payload) }   // deserialise
    func payload() -> [UInt8] { encodeUTF8(message) }                // serialise
    func perform(_ context: Context) async throws {                 // the work
        await context.kv?.putString("last-job", message)            // jobs reach bindings
    }
}
```

Inside `perform`, capabilities are ambient just as in a handler: `Post.save()`, `KV.current` and the rest work without threading anything through. See [the ambient accessors](bindings.md) for the full set.

## Enqueueing

Enqueue the job in a handler, on the queue binding:

```swift
try await LogJob(message: "hi").enqueue(on: request.bindings.queue)
```

`enqueue` wraps the job in a wire envelope (`[u16 nameLen][name][payload]`) and sends it on the queue.

## Job discovery

You don't wire jobs up by hand. **Every type conforming to `Job` under `Sources/App/Jobs/` is discovered at build time and registered**, at any depth, so organise them into subfolders (`Jobs/Email/`, `Jobs/Billing/`) freely. Order is irrelevant because jobs dispatch by name. Drop a file in and it runs.

The consumer calls a generated `buildJobs()` (under `Sources/App/Generated/`, never hand-edited) that registers every discovered job and wires the schedule's tick in. Two jobs sharing a `static var name` fail the build, since they would collide on dispatch. Under the hood, the registry holds concrete closures (`([UInt8], Context) async throws -> Void`); `register<J: Job>` captures each type statically.

### Scaffolding a job

`plumekit generate job SendEmail` writes `Sources/App/Jobs/SendEmailJob.swift`, registered on the next build.

## Consumers on both targets

Only the consumer differs per target; the job code does not.

### Native

`PlumeServer.run(..., jobs: buildJobs())` spawns a background loop that drains the in-process queue and dispatches each message. `plumekit serve` runs it automatically.

### Cloudflare

A wasm export `plumekit_queue` (alongside `plumekit_handle`) dispatches one message. `worker.mjs`'s `queue(batch, env)` handler delivers each message from `batch.messages` to it; the export is JSPI-suspendable, so `perform` can `await` host calls. The consumer is wired by a `[[queues.consumers]]` binding in `wrangler.toml`.

Two Cloudflare-specific details:

- a `MessageBatch` is **not** iterable; iterate `batch.messages`;
- queue bodies must be sent with `contentType: "bytes"` to round-trip raw bytes (the consumer receives an `ArrayBuffer`).

## Scheduled tasks

Recurring work ("run this every N minutes / hourly / daily") rides the same core as jobs. Unlike jobs, schedules are **declared by hand in one place**: `registerSchedules(_ schedule: inout Schedule)` in `Sources/App/Schedules.swift` (its own file, like `Routes.swift`):

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

The file is optional: without it the generated schedule is simply empty.

### Cadences

The cadences are `.minute`, `.minutes(n)`, `.hourly(atMinute:)` and `.daily(hour:minute:)`, all **UTC**. Due-ness is matched statelessly against the wall clock, with cron semantics: a missed tick is **skipped**, not replayed. For work that must not be lost, have the task enqueue a Job, as in the example above. A failing task is logged and doesn't block the other tasks.

### Who ticks the schedule

Only the ticker differs per target; the schedule doesn't.

| Target | Ticker |
|---|---|
| Native | `PlumeServer.run` ticks on minute boundaries; `plumekit serve` runs it automatically |
| Cloudflare | a Cron Trigger invokes the worker's `scheduled` handler, which forwards a tick envelope through the job path |
| AWS | an EventBridge 1-minute rule sends the same envelope through the queue |

On Cloudflare, **one** every-minute cron in `wrangler.toml` drives all tasks:

```toml
[triggers]
crons = ["* * * * *"]
```

### Generated plumbing

`buildSchedule()` wraps your `registerSchedules`, and the generated `buildJobs()` does `registry.include(buildSchedule())`. The schedule's tick is therefore a registered job on the queue-backed targets, while `PlumeServer.run(schedule:)` also ticks it natively. You only write `registerSchedules`.
