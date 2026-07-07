import _Concurrency
/// The entry point of a PlumeKit app: a route table plus a middleware stack.
///
/// `Application` is platform-agnostic. Adapters (the native `PlumeServer`, the
/// `PlumeWorker` Wasm glue) decode a transport request into a `Request`, call
/// `handle(_:)`, and serialize the returned `Response` back onto the wire.
///
/// It is a `final class` (no dynamic dispatch) holding concrete function values
/// for routes and middleware — no existentials, no reflection — so it remains
/// valid under Embedded Swift.
public final class Application: @unchecked Sendable {
    // Routes and middleware are registered once at build time and only read
    // during dispatch; the worker/server runtimes are single-threaded. Hence
    // @unchecked Sendable, so the app can be captured by the handler Task.
    private var router = Router()
    private var middleware: [MiddlewareFunction] = []

    public init() {}

    /// The registered routes as (method, path) pairs — for tooling (`plumekit routes`).
    public var routeList: [(method: String, path: String)] { router.descriptions }

    // MARK: - Route registration

    /// Register a handler for an arbitrary method.
    public func on(_ method: HTTPMethod, _ path: String, _ handler: @escaping Responder) {
        router.add(method, path, handler)
    }

    public func get(_ path: String, _ handler: @escaping Responder) { on(.get, path, handler) }
    public func post(_ path: String, _ handler: @escaping Responder) { on(.post, path, handler) }
    public func put(_ path: String, _ handler: @escaping Responder) { on(.put, path, handler) }
    public func patch(_ path: String, _ handler: @escaping Responder) { on(.patch, path, handler) }
    public func delete(_ path: String, _ handler: @escaping Responder) { on(.delete, path, handler) }
    public func head(_ path: String, _ handler: @escaping Responder) { on(.head, path, handler) }
    public func options(_ path: String, _ handler: @escaping Responder) { on(.options, path, handler) }

    // MARK: - Middleware

    /// Register closure-shaped middleware.
    public func use(_ middleware: @escaping MiddlewareFunction) {
        self.middleware.append(middleware)
    }

    /// Register a `Middleware`-conforming value. It is adapted to a closure here,
    /// so the stored stack never holds an existential.
    public func use<M: Middleware>(_ middleware: M) {
        self.middleware.append(middleware.asMiddlewareFunction())
    }

    // MARK: - Custom error pages

    private var errorPages: [Int: @Sendable (Request) async -> Response] = [:]

    /// Register a custom page for an error status. It applies to the framework-generated
    /// 404 / 405 / 500, AND to any `status >= 400` a handler or middleware returns with an
    /// empty body (e.g. a bare `.status(403)` / `.status(401)`), so you can brand those too.
    /// A status without a registered page keeps the default plain-text response. On
    /// `plumekit serve` in development the 500 dev error page still takes precedence locally.
    ///
    ///     app.errorPage(404) { _ in .html(NotFoundView.render(), status: 404) }
    ///     app.errorPage(500) { _ in .html(ServerErrorView.render(), status: 500) }
    public func errorPage(_ status: Int, _ handler: @escaping @Sendable (Request) async -> Response) {
        errorPages[status] = handler
    }

    /// The registered custom page for `status`, or nil if none — callers fall back to the
    /// default. Public so adapters (the native server's 500 path) can consult it.
    public func renderErrorPage(_ status: Int, for request: Request) async -> Response? {
        guard let handler = errorPages[status] else { return nil }
        return await handler(request)
    }

    // MARK: - Dispatch

    /// Route `request` through the middleware stack to its handler and return the
    /// response. Unmatched paths yield 404; matched paths with the wrong method
    /// yield 405. Handlers are `async throws`; a thrown error becomes a 500.
    public func handle(_ request: Request) async -> Response {
        do {
            return try await handleThrowing(request)
        } catch {
            return await renderErrorPage(500, for: request) ?? defaultErrorResponse(500)
        }
    }

    /// Like `handle(_:)`, but lets a thrown error propagate to the caller. Adapters
    /// that can render errors richly use this — the native dev server catches here
    /// and shows the error page. (The rendering lives in the adapter because the
    /// embedded-Wasm guest can't stringify an arbitrary `any Error`.)
    public func handleThrowing(_ request: Request) async throws -> Response {
        // Bind the request's context as the ambient one, so ORM calls (`Post.all()`)
        // and the `.current` binding accessors (`KV.current`, …) can default to it.
        // Native builds bind it task-locally, so concurrent apps in one process (e.g.
        // parallel test suites) never see each other's context; the embedded guest
        // keeps the plain-global assignment (one request per instance, and the
        // straight-line form keeps Embedded SILGen happy).
        #if hasFeature(Embedded)
        RequestContext.current = request.context
        return try await respondThrowing(request)
        #else
        return try await RequestContext.withValue(request.context) {
            try await respondThrowing(request)
        }
        #endif
    }

    /// The dispatch body of `handleThrowing`, run with the request's context already
    /// bound as the ambient one.
    private func respondThrowing(_ request: Request) async throws -> Response {
        var response = try await invoke(request, at: 0)

        // The single place error pages are applied: any error status with no body of its
        // own (the framework's 404/405, a thrown 500 caught upstream, or an app-returned
        // bare `.status(403)`/`401`/…) gets the registered custom page, else the built-in
        // default. Runs exactly once — `dispatch` no longer renders pages itself, so a
        // custom page that returns an empty body isn't invoked twice. A response with a
        // body of its own is left untouched.
        if response.body.isEmpty, response.status >= 400 {
            response = await renderErrorPage(response.status, for: request)
                ?? defaultErrorResponse(response.status)
        }

        // A flash shows exactly once: when an HTML page renders while the cookie is
        // present (and the response isn't setting a new flash), clear it. Non-HTML
        // responses (a JSON poll, an XHR) leave it alone, so a background request
        // between the redirect and the page load can't eat the message.
        if extractCookie(request, name: Flash.cookieName) != nil,
           let contentType = response.headers.first("content-type"),
           asciiHasPrefix(contentType, "text/html"),
           !response.headers.all("set-cookie").contains(where: { asciiHasPrefix($0, Flash.cookieName + "=") }) {
            response.headers.add("set-cookie", Flash.clearCookie)
        }
        return response
    }

    /// Recursively walk the middleware stack. The `next` responder handed to each
    /// middleware re-enters at the following index. Recursion (rather than
    /// pre-composing nested async closures) keeps Embedded SILGen happy.
    private func invoke(_ request: Request, at index: Int) async throws -> Response {
        if index < middleware.count {
            let current = middleware[index]
            return try await current(request, { [self] req in
                try await invoke(req, at: index + 1)
            })
        }
        return try await dispatch(request)
    }

    /// Terminal responder: match a route and invoke its handler.
    private func dispatch(_ request: Request) async throws -> Response {
        var result = router.match(method: request.method, path: request.path)
        // A HEAD with no HEAD route falls back to the GET handler; the body is dropped
        // below so the response is headers-only, as HEAD requires.
        if request.method == .head {
            if case .found = result {} else {
                result = router.match(method: .get, path: request.path)
            }
        }
        switch result {
        case .found(let handler, let parameters):
            var matched = request
            matched.parameters = parameters
            var response = try await handler(matched)
            if request.method == .head { response.body = [] }
            return response
        case .methodNotAllowed:
            return Response.status(405)   // custom/default page applied once in respondThrowing
        case .notFound:
            return Response.status(404)
        }
    }

    /// The built-in plain-text page for an error status, used when no custom page is set.
    private func defaultErrorResponse(_ status: Int) -> Response {
        switch status {
        case 404: return .text("404 Not Found", status: 404)
        case 405: return .text("405 Method Not Allowed", status: 405)
        case 500: return .text("500 Internal Server Error", status: 500)
        default: return .text("\(status) \(Response(status: status).reasonPhrase)", status: status)
        }
    }
}