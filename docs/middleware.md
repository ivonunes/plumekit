# Middleware

Middleware wraps every request on its way to a route handler, and every response on
the way back out. Use it for cross-cutting concerns (logging, authentication, CSRF,
method override) that should apply across routes rather than inside one handler.

Middleware is stored as concrete function values, so the stack runs identically
on the native server and the Cloudflare Worker.

## The signature

A middleware is a function that receives the request and the `next` responder in the
chain, and returns a response:

```swift
public typealias MiddlewareFunction = (Request, Responder) async throws -> Response
```

It may do three things, in any combination:

- **inspect or transform** the request before calling `next`,
- **call `next(request)`** to continue down the chain (and eventually reach the route
  handler), and
- **inspect or transform** the response `next` returns, or **skip `next` entirely**
  to short-circuit.

## Registering middleware

Register middleware on the `Application` with `use`. The closure form is the common
case:

```swift
let app = Application()

// Log every request through the platform log seam
// (console.log on Workers, stdout natively).
app.use { request, next in
    let response = try await next(request)
    request.context.log("\(request.method.name) \(request.path) -> \(response.status)")
    return response
}
```

To short-circuit, return a response without calling `next`:

```swift
app.use { request, next in
    guard request.headers.first("x-api-key") == "let-me-in" else {
        return .text("unauthorized", status: 401)
    }
    return try await next(request)
}
```

To rewrite the request, make a mutable copy and pass it on. `Request` is a value
type, so mutations are local until you forward them:

```swift
app.use { request, next in
    var forwarded = request
    forwarded.headers.set("x-request-id", makeID())
    return try await next(forwarded)
}
```

## The protocol form

For reusable middleware with configuration or state, conform a concrete type to
`Middleware`:

```swift
public protocol Middleware {
    func respond(to request: Request, next: Responder) async throws -> Response
}
```

```swift
struct RequireHTTPS: Middleware {
    func respond(to request: Request, next: Responder) async throws -> Response {
        if request.headers.first("x-forwarded-proto") == "http" {
            return .redirect(to: "https://…", status: 308)
        }
        return try await next(request)
    }
}

app.use(RequireHTTPS())
```

`use(_:)` adapts the value to a `MiddlewareFunction` at registration time.

## Ordering

Registration order is nesting order. The **first** middleware registered is the
**outermost**: it runs first on the way in and last on the way out. Given

```swift
app.use(A)
app.use(B)
app.use(C)
```

a request flows `A → B → C → handler`, and the response returns `handler → C → B →
A`. Register broad, early-exit concerns (logging, method override, auth) before
narrower ones. A typical order:

```swift
app.use(loggingMiddleware)      // outermost: sees final status
app.use(methodOverride())       // rewrite POST → PUT/PATCH/DELETE before routing
app.use(csrfProtection())       // reject unsafe requests without a valid token
app.use(identityMiddleware(sessions))   // resolve request.principal
```

## Error handling

Handlers and middleware are `async throws`. A thrown error that is not caught by a
middleware propagates to the framework, which returns a **500 Internal Server
Error**. To translate errors into specific responses, catch them in a middleware:

```swift
app.use { request, next in
    do {
        return try await next(request)
    } catch is NotFound {
        return .status(404)
    }
}
```

## Scope

Middleware registered with `use` runs for **every** request. To apply middleware
to a subset of routes, use a route group (see [Routing](routing.md));
alternatively, gate on the request inside the middleware:

```swift
app.use { request, next in
    guard request.path.hasPrefix("/admin") else { return try await next(request) }
    // …admin-only checks…
    return try await next(request)
}
```

## Built-in middleware

PlumeKit ships several middleware factories in `PlumeCore`:

- **`methodOverride()`**: rewrites a `POST` into `PUT`/`PATCH`/`DELETE` when the body
  carries a `_method` field (or an `X-HTTP-Method-Override` header). HTML forms can
  only issue `GET`/`POST`, so this lets a form drive a resourceful route. It runs
  before routing, so the overridden method is what matches. See [Forms](forms.md).

- **`csrfProtection(secretName:)`**: rejects unsafe requests (`POST`/`PUT`/`PATCH`/
  `DELETE`) that lack a valid CSRF token, validated timing-safely against a signing
  secret read from the secrets binding (default `"CSRF_SECRET"`). JSON-body requests
  and bearer-token requests are exempt (they are not exposed to CSRF); it guards
  ambient-credential form and multipart submissions. See [Forms](forms.md).

- **`identityMiddleware(_:cookieName:)`**: resolves the authenticated identity from a
  signed cookie session or an `Authorization: Bearer` token and sets
  `request.principal`, so downstream handlers and policies can read `currentUser`.
  See [Auth](auth.md).

Register the ones you need in `buildApp()`:

```swift
app.use(methodOverride())
app.use(csrfProtection())
app.use(identityMiddleware(sessions))
```
