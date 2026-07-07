/// The bindings for the current request. `Application.handle` binds this around each
/// handler, so ORM calls (`Post.all()`) and the `.current` binding accessors
/// (`KV.current`, `Cache.current`, `Mailer.current`, …) can default to it — no need to
/// thread `request` through. Outside a request (migrations, seeders, tests, background
/// jobs) reach bindings explicitly (e.g. through `request.bindings`).
///
/// On native builds the request-scoped value is a **task-local** — several apps (or test
/// suites, which Swift Testing runs in parallel in one process) can dispatch concurrently
/// without seeing each other's context. Long-lived non-request code (server startup,
/// migrations, the console, schedule ticks) still *assigns* `RequestContext.current =
/// context`; that writes a process-global fallback which reads fall back to when no
/// task-local binding is in scope.
///
/// The embedded-Wasm guest keeps the original plain global: `@TaskLocal.withValue`
/// doesn't compile under Embedded (the same reason `ORMClock` is a global), and the
/// guest handles one request per instance, so a global is safe there.
public enum RequestContext {
    #if hasFeature(Embedded)
    nonisolated(unsafe) public static var current: Context? = nil

    /// Bind `context` as the ambient one for the duration of `operation`. On the
    /// embedded guest this assigns the global (single request per instance, so no
    /// restore is needed — matching the previous behavior).
    public static func withValue<R>(
        _ context: Context?, operation: () async throws -> R
    ) async rethrows -> R {
        current = context
        return try await operation()
    }
    #else
    /// The request-scoped binding: set by `withValue` around dispatch; visible only to
    /// the binding task and its children (child tasks and `Task {}` inherit it).
    @TaskLocal private static var taskLocal: Context?

    /// The process-global fallback: written by plain assignment (`RequestContext.current
    /// = context`) from startup-style code that isn't scoped to a task.
    nonisolated(unsafe) private static var fallback: Context? = nil

    /// Reads see the task-local binding first, then the process-global fallback.
    /// Assignment writes the fallback (use `withValue` for request-scoped binding).
    public static var current: Context? {
        get { taskLocal ?? fallback }
        set { fallback = newValue }
    }

    /// Bind `context` as the ambient one for the duration of `operation`, scoped to the
    /// current task — concurrent tasks each see only their own binding.
    public static func withValue<R>(
        _ context: Context?, operation: () async throws -> R
    ) async rethrows -> R {
        try await $taskLocal.withValue(context, operation: operation)
    }
    #endif
}

/// Resolve an ambient binding or trap with a clear message — using a capability you
/// didn't enable, or reaching for one outside a request, is a programming error (and
/// embedded Swift can't throw a custom error type).
private func ambientBinding<T>(_ value: T?, _ capability: String) -> T {
    guard let value else {
        fatalError("`\(capability)` is not available. Enable it in plumekit.toml, and use "
            + "it inside a request — or reach it explicitly (`request.bindings`) outside one.")
    }
    return value
}

extension Database {
    /// The database bound to the current request. Prefer the ORM (`Post.all()`); use this
    /// for raw SQL: `try await Database.current.query(sql, params)`. Inside
    /// `db.transaction { … }` this is the transaction's own handle.
    public static var current: Database {
        #if !hasFeature(Embedded)
        if let transaction = TransactionContext.database { return transaction }
        #endif
        return ambientBinding(RequestContext.current?.database, "database")
    }
}
extension KV {
    public static var current: KV { ambientBinding(RequestContext.current?.kv, "kv") }
}
extension Cache {
    public static var current: Cache { ambientBinding(RequestContext.current?.cache, "cache") }
}
extension Storage {
    /// The object-storage binding for the current request.
    public static var current: Storage { ambientBinding(RequestContext.current?.storage, "storage") }
}
extension Queue {
    public static var current: Queue { ambientBinding(RequestContext.current?.queue, "queue") }
}
extension Secrets {
    public static var current: Secrets { ambientBinding(RequestContext.current?.secrets, "secrets") }
}
extension HTTP {
    /// The outbound-HTTP binding for the current request.
    public static var current: HTTP { ambientBinding(RequestContext.current?.http, "http") }
}
extension Mailer {
    public static var current: Mailer { ambientBinding(RequestContext.current?.mailer, "mailer") }
}
