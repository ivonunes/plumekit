import _Concurrency
/// A function that turns a `Request` into a `Response`, asynchronously.
///
/// Handlers are `async throws` so they can `await` host bindings (e.g. KV) and
/// surface errors. This is a concrete function type — not an existential — so it
/// is safe to store in arrays and compose under Embedded Swift. Synchronous
/// routes are simply async closures that never `await`.
public typealias Responder = (Request) async throws -> Response

/// A function-shaped middleware: receives the request and the `next` responder
/// in the chain, and returns a response. Storing these (rather than `any
/// Middleware`) is what keeps the middleware stack Embedded-clean.
public typealias MiddlewareFunction = (Request, Responder) async throws -> Response

/// Ergonomic protocol form of middleware.
///
/// Conform a concrete type and register it with `Application.use(_:)`. Internally
/// it is adapted to a `MiddlewareFunction` closure at registration time, so no
/// existential (`any Middleware`) is ever stored — preserving Embedded-cleanliness.
public protocol Middleware {
    /// Inspect/short-circuit the request, optionally calling `next` to continue.
    func respond(to request: Request, next: Responder) async throws -> Response
}

extension Middleware {
    /// Adapt this middleware to a stored `MiddlewareFunction`. Defined as a
    /// protocol-extension method (rather than an inline closure in `use<M>`) to
    /// keep the generic async closure out of `Application`'s SILGen.
    func asMiddlewareFunction() -> MiddlewareFunction {
        { request, next in try await respond(to: request, next: next) }
    }
}