#if !hasFeature(Embedded)
import _Concurrency
#endif

// Per-request values that views read while rendering. The framework sets these
// before a handler renders; compiled views read them synchronously. Kept here in
// PlumeRuntime (which generated views import) so `@csrf` and friends need no
// threaded parameters.
//
// Purely synchronous storage: no async here, so PlumeRuntime stays usable on its
// own (e.g. a static-site generator) with no concurrency runtime. The framework
// (PlumeCore) scopes the value around each request. Single-threaded in the Wasm
// guest (a plain global); on the native server each request runs concurrently, so
// it's a task-local there.

/// The active language for a request plus the lookup that renders a key. A reference
/// type so the framework can bind it once and the app can still `useLocale(_)` to
/// change the language mid-request (e.g. to a signed-in user's saved preference).
public final class LocalizationState: @unchecked Sendable {
    public var locale: String
    let render: @Sendable (String, String, [String: String]) -> String
    let table: @Sendable (String) -> String   // locale → JSON, injected for the @script client

    public init(locale: String,
                render: @escaping @Sendable (String, String, [String: String]) -> String,
                table: @escaping @Sendable (String) -> String = { _ in "{}" }) {
        self.locale = locale
        self.render = render
        self.table = table
    }

    /// The active locale's strings as a JSON object, for the compiled-mode client `t()`.
    public var currentTableJSON: String { table(locale) }
}

public enum RenderContext {
    #if hasFeature(Embedded)
    // The embedded guest is single-threaded and has no task-locals.
    public nonisolated(unsafe) static var csrfToken: String = ""
    public nonisolated(unsafe) static var localization: LocalizationState?
    #else
    @TaskLocal public static var csrfToken: String = ""
    @TaskLocal public static var localization: LocalizationState?
    #endif

    /// The current request's CSRF token, or "" when CSRF protection isn't
    /// configured. `@csrf` renders this into a hidden form field.
    public static var currentCSRFToken: String { csrfToken }
}

/// Translate `key` for the current request's language, substituting `{name}`
/// placeholders from `params`. Falls back to `key` when no translations are set.
/// Works in handlers and directly in a view: `{t("welcome.title")}`.
public func t(_ key: String, _ params: [String: String] = [:]) -> String {
    guard let state = RenderContext.localization else { return key }
    return state.render(key, state.locale, params)
}

/// Override the active language for the rest of this request — e.g. a signed-in
/// user's saved preference, which should win over the negotiated language. No effect
/// if localization isn't installed.
public func useLocale(_ locale: String) {
    RenderContext.localization?.locale = locale
}

/// The active language for this request, or "" if localization isn't installed.
public var currentLocale: String { RenderContext.localization?.locale ?? "" }
