import _Concurrency

// Route groups: register a set of routes that share a path
// prefix and/or middleware. Group middleware runs after the global stack and only for
// routes in the group — the scope is achieved by wrapping each grouped handler in its
// own middleware chain, so the Router and dispatch path stay unchanged (and
// Embedded-clean: concrete function values, recursive dispatch, no existentials).

extension Application {
    /// Register a group of routes sharing a path `prefix` and/or `middleware`.
    ///
    ///     app.group("/admin", middleware: [requireAdmin]) { admin in
    ///         admin.get("/users") { ... }              // GET /admin/users, behind requireAdmin
    ///         admin.resources("posts", PostController())
    ///     }
    ///
    /// Groups nest — prefixes compose and middleware accumulates.
    public func group(_ prefix: String = "",
                      middleware: [MiddlewareFunction] = [],
                      _ build: (RouteGroup) -> Void) {
        build(RouteGroup(app: self, prefix: prefix, middleware: middleware))
    }
}

/// A path-prefix + middleware scope for registering routes. Created by
/// `Application.group(_:middleware:_:)`; you never construct it directly.
public final class RouteGroup {
    let app: Application
    let prefix: String
    let middleware: [MiddlewareFunction]

    init(app: Application, prefix: String, middleware: [MiddlewareFunction]) {
        self.app = app
        self.prefix = prefix
        self.middleware = middleware
    }

    /// Register a handler for an arbitrary method within this group.
    public func on(_ method: HTTPMethod, _ path: String, _ handler: @escaping Responder) {
        let chain = ScopedChain(middleware: middleware, handler: handler)
        app.on(method, prefix + path) { try await chain.run($0) }
    }

    public func get(_ path: String, _ handler: @escaping Responder) { on(.get, path, handler) }
    public func post(_ path: String, _ handler: @escaping Responder) { on(.post, path, handler) }
    public func put(_ path: String, _ handler: @escaping Responder) { on(.put, path, handler) }
    public func patch(_ path: String, _ handler: @escaping Responder) { on(.patch, path, handler) }
    public func delete(_ path: String, _ handler: @escaping Responder) { on(.delete, path, handler) }
    public func head(_ path: String, _ handler: @escaping Responder) { on(.head, path, handler) }
    public func options(_ path: String, _ handler: @escaping Responder) { on(.options, path, handler) }

    /// A nested group: the prefix and middleware compose with this group's.
    public func group(_ prefix: String = "",
                      middleware: [MiddlewareFunction] = [],
                      _ build: (RouteGroup) -> Void) {
        build(RouteGroup(app: app, prefix: self.prefix + prefix, middleware: self.middleware + middleware))
    }

    /// Wire a controller's conventional RESTful routes within this group.
    public func resources(_ path: String, _ controller: some Controller) {
        get(path) { try await controller.index($0) }
        get(path + "/new") { try await controller.new($0) }       // literal beats /:id via specificity
        post(path) { try await controller.create($0) }
        get(path + "/:id") { try await controller.show($0) }
        get(path + "/:id/edit") { try await controller.edit($0) }
        put(path + "/:id") { try await controller.update($0) }
        patch(path + "/:id") { try await controller.update($0) }
        delete(path + "/:id") { try await controller.destroy($0) }
    }
}

/// Runs a route's scoped middleware then its handler. Recursive dispatch (like
/// `Application.invoke`) keeps Embedded SILGen happy — no pre-composed async closures.
struct ScopedChain {
    let middleware: [MiddlewareFunction]
    let handler: Responder

    func run(_ request: Request) async throws -> Response { try await invoke(request, 0) }

    private func invoke(_ request: Request, _ index: Int) async throws -> Response {
        if index < middleware.count {
            return try await middleware[index](request) { try await invoke($0, index + 1) }
        }
        return try await handler(request)
    }
}
