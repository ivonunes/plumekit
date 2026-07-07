import _Concurrency

// RESTful resource controllers. A controller groups the seven
// conventional actions for a resource; `app.resources(_:_:)` wires the routes.
// Concrete generic dispatch (`some Controller`) — no existentials, Embedded-clean.
// Each action has a default 405 impl, so a controller implements only what it
// supports.
public protocol Controller {
    func index(_ request: Request) async throws -> Response    // GET    /path
    func new(_ request: Request) async throws -> Response      // GET    /path/new       (form to create)
    func create(_ request: Request) async throws -> Response   // POST   /path
    func show(_ request: Request) async throws -> Response     // GET    /path/:id
    func edit(_ request: Request) async throws -> Response     // GET    /path/:id/edit   (form to edit)
    func update(_ request: Request) async throws -> Response   // PUT/PATCH /path/:id
    func destroy(_ request: Request) async throws -> Response  // DELETE /path/:id
}

extension Controller {
    public func index(_ request: Request) async throws -> Response { Self.unsupported() }
    public func new(_ request: Request) async throws -> Response { Self.unsupported() }
    public func create(_ request: Request) async throws -> Response { Self.unsupported() }
    public func show(_ request: Request) async throws -> Response { Self.unsupported() }
    public func edit(_ request: Request) async throws -> Response { Self.unsupported() }
    public func update(_ request: Request) async throws -> Response { Self.unsupported() }
    public func destroy(_ request: Request) async throws -> Response { Self.unsupported() }
    static func unsupported() -> Response { .text("405 Method Not Allowed", status: 405) }
}

extension Application {
    /// Wire the conventional RESTful routes for a resource to a controller's
    /// actions. Unimplemented actions fall back to 405.
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
