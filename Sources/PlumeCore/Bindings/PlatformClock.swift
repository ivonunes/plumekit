import _Concurrency

// The framework's wall-clock seam. Embedded Swift has no wall clock (only a
// monotonic one via WASI) and the core is Foundation-free, so the actual time
// source is INSTALLED per platform:
//   • native  — PlumeServer installs a Foundation `Date`-based clock.
//   • wasm    — the worker installs a `host_now` (JS `Date.now()`) clock.
// A clock is a stateless process-wide function (not per-request state), so a
// global is safe here — unlike the ambient Database, which would need a
// per-request task-local (and @TaskLocal does not compile under embedded wasm).
// The ORM's timestamps and the auth session middleware both read it; PlumeORM
// re-exports it under its historical `ORMClock` name.
public enum PlatformClock {
    /// Epoch milliseconds. Defaults to 0 until a platform installs a real clock.
    nonisolated(unsafe) public static var now: @Sendable () -> Int64 = { 0 }
}
