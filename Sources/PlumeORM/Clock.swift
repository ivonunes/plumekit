import _Concurrency

// The ORM's wall-clock seam, for auto-managed `createdAt`/`updatedAt`. Embedded
// Swift has no wall clock (only a monotonic one via WASI), and PlumeORM is
// Foundation-free, so the actual time source is INSTALLED per platform:
//   • native  — PlumeServer installs a Foundation `Date`-based clock.
//   • wasm    — the worker installs a `host_now` (JS `Date.now()`) clock.
// A clock is a stateless process-wide function (not per-request state), so a
// global is safe here — unlike the ambient Database, which would need a
// per-request task-local (and @TaskLocal does not compile under embedded wasm).
public enum ORMClock {
    /// Epoch milliseconds. Defaults to 0 until a platform installs a real clock.
    nonisolated(unsafe) public static var now: @Sendable () -> Int64 = { 0 }
}

// ISO-8601 timestamps for schemas that store `created_at`/`updated_at` as TEXT (the
// common case when ADOPTING an existing database, vs PlumeKit's native epoch-millis
// INTEGER). Produces exactly the shape JavaScript's `Date.toISOString()` emits —
// `YYYY-MM-DDTHH:mm:ss.sssZ`, UTC, millisecond precision — so an auto-touched row is
// byte-identical to one written by a Node/Workers seeder. Pure integer civil-date
// math (Howard Hinnant's algorithm); no Foundation, no Unicode — Embedded-clean.

/// Current wall-clock time as an ISO-8601 UTC string (from the installed `ORMClock`).
public func ormNowISO() -> String { isoFromEpochMillis(ORMClock.now()) }

/// Convert epoch milliseconds to `YYYY-MM-DDTHH:mm:ss.sssZ` (UTC).
public func isoFromEpochMillis(_ millis: Int64) -> String {
    let msPerDay: Int64 = 86_400_000
    var days = millis / msPerDay
    var ms = millis % msPerDay
    if ms < 0 { ms += msPerDay; days -= 1 }     // floor toward -∞ for pre-epoch instants

    // days since 1970-01-01 → civil (year, month, day), shifting the era to 0000-03-01.
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097                    // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365   // [0, 399]
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)                  // [0, 365]
    let mp = (5 * doy + 2) / 153                  // [0, 11]
    let day = Int(doy - (153 * mp + 2) / 5 + 1)   // [1, 31]
    let month = Int(mp < 10 ? mp + 3 : mp - 9)    // [1, 12]
    let year = Int(y + (month <= 2 ? 1 : 0))

    let hour = Int(ms / 3_600_000)
    let minute = Int((ms % 3_600_000) / 60_000)
    let second = Int((ms % 60_000) / 1000)
    let milli = Int(ms % 1000)

    return pad4(year) + "-" + pad2(month) + "-" + pad2(day) + "T"
        + pad2(hour) + ":" + pad2(minute) + ":" + pad2(second) + "." + pad3(milli) + "Z"
}

// Zero-padded ASCII decimals (only `String(Int)` + concatenation — the same
// embedded-safe primitives `integerLiteral` uses; no `String(format:)`/locale).
func pad2(_ v: Int) -> String { v < 10 ? "0" + String(v) : String(v) }
func pad3(_ v: Int) -> String { v < 10 ? "00" + String(v) : (v < 100 ? "0" + String(v) : String(v)) }
func pad4(_ v: Int) -> String {
    if v < 10 { return "000" + String(v) }
    if v < 100 { return "00" + String(v) }
    if v < 1000 { return "0" + String(v) }
    return String(v)
}
