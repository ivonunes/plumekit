# Routing

Routing decides which handler answers each request, based on its HTTP method and path. You declare routes on the `Application` you build in `buildApp()`, and the router dispatches every incoming request to the matching handler. Routing is deliberately simple and allocation-light: a flat route table matched by comparing pre-parsed path segments as UTF-8 bytes, with no regex and no Foundation, so it runs identically on the native server and the Cloudflare Worker.

## Registering routes

There is a registration helper for each HTTP method, plus `on(_:_:_:)` for registering with the method as a value:

```swift
let app = Application()

app.get("/")                { _ in .text("home") }
app.post("/posts")          { request in … }
app.put("/posts/:id")       { request in … }
app.patch("/posts/:id")     { request in … }
app.delete("/posts/:id")    { request in … }
app.head("/health")         { _ in .status(200) }
app.options("/posts")       { _ in .status(204) }

app.on(.get, "/legacy")     { _ in .text("via on()") }
```

The supported methods are `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD` and `OPTIONS`.

## Handlers

A handler is a `Responder`, an `async throws` closure that takes a `Request` and returns a `Response`:

```swift
public typealias Responder = (Request) async throws -> Response
```

`async` lets a handler `await` host bindings, such as a KV read or a SQL query. A synchronous handler is simply a closure that never awaits.

A thrown error is caught by the framework and returned as a 500, so handlers can `try` freely:

```swift
app.get("/posts/:id") { request in
    let db = request.bindings.database
    guard let id = Int(request.parameters["id"] ?? "") ,
          let post = try await Post.find(id, in: db) else {
        return .status(404)
    }
    return .text(post.title)
}
```

The error is always logged to stdout.

### The development error page

Under `plumekit serve` and `plumekit dev`, which set `PLUMEKIT_ENV=development`, the native server renders a development error page instead of the bare 500. It shows the error's type and description, the request (method, path, query, headers, a body preview) and the app's route table. In production, with no env var set, the response stays a clean 500.

The page is native-only by design; the Wasm guest cannot stringify errors.

## Path parameters

Often a route needs to capture part of the path, such as a post's id. A segment written `:name` captures whatever appears in that position. Read captured values from `request.parameters`, which returns `String?`:

```swift
app.get("/users/:userID/posts/:postID") { request in
    let userID = request.parameters["userID"] ?? ""
    let postID = request.parameters["postID"] ?? ""
    return .text("user \(userID), post \(postID)")
}
```

Matching is exact per segment. Empty path segments are ignored, so a trailing slash does not change matching: `/posts` and `/posts/` match the same route.

When more than one route matches a path, the most specific wins: a literal segment beats `:param`, which beats a wildcard. That is how `GET /posts/new` reaches its own route even when `GET /posts/:id` is also registered.

### Wildcards

A `*name` segment captures the rest of the path (one or more segments, slash-joined) into `request.parameters["name"]`. It must be the last segment:

```swift
app.get("/files/*path") { request in
    request.parameters["path"]     // "/files/a/b/c.txt" → "a/b/c.txt"
}
```

`*name` requires at least one trailing segment. `**name` also matches zero, so `/assets/**path` matches the bare `/assets` too.

> **Note:** Regex patterns are not supported; a regex engine is not linkable in the Wasm guest. Validate a captured segment in the handler instead.

## Query parameters

The raw query string is available as `request.query`. The parsed form is `request.queryParams`, a `FormParams` with `%XX` and `+` decoding:

```swift
app.get("/search") { request in
    let term = request.queryParams["q"] ?? ""
    let page = request.queryParams.int("page") ?? 1
    return .text("q=\(term) page=\(page)")
}
```

## The request

A handler receives an immutable `Request` value. The router populates its `parameters` before dispatch.

| Property | Type | Notes |
|---|---|---|
| `method` | `HTTPMethod` | `.get`, `.post`, … ; `method.name` is `"GET"`, etc. |
| `path` | `String` | Path only, no query string |
| `query` | `String` | Raw query string (without the `?`) |
| `headers` | `Headers` | Case-insensitive, order-preserving |
| `body` | `[UInt8]` | Raw request body |
| `bodyText` | `String` | Body decoded as UTF-8 |
| `parameters` | `Parameters` | Path parameters; `request.parameters["id"]` → `String?` |
| `queryParams` | `FormParams` | Parsed query string |
| `context` | `Context` | Per-request host capabilities and logging |
| `bindings` | `Bindings` | Typed, non-optional view of declared capabilities |
| `principal` | `Principal?` | The authenticated identity, if any |

Headers are read case-insensitively:

```swift
let contentType = request.headers.first("content-type")
let accepts     = request.headers.all("accept")
```

Bindings are reached through `request.bindings` (typed and non-optional, generated from the capabilities you declare in `plumekit.toml`) or `request.context` (optional). See [Bindings & drivers](bindings.md).

## The response

Build responses with `Response`'s convenience constructors, or the initialiser for full control:

```swift
.text("hello")                         // text/plain; charset=utf-8
.text("nope", status: 404)
.html("<h1>hi</h1>")                    // text/html; charset=utf-8
.html(bytes: renderedHTML)             // pre-rendered UTF-8 bytes (e.g. Plume)
.json("{\"ok\":true}")                 // pre-serialised JSON string
.json(.object([("ok", .bool(true))]))  // from a JSONValue
.status(204)                           // bare status, empty body
.redirect(to: "/posts")               // 303 See Other by default

Response(status: 201, headers: headers, body: bytes)   // full control
```

`Response` exposes `status`, `headers`, `body` (`[UInt8]`), `bodyText` and `reasonPhrase`. Set headers before returning:

```swift
var response = Response.text("created", status: 201)
response.headers.set("location", "/posts/42")
return response
```

### Streaming bodies

Sometimes a response is too large or too slow to buffer whole, such as an export or a generated download of unknown size. A response can produce its body incrementally instead:

```swift
app.get("/posts.csv") { _ in
    .stream(contentType: "text/csv") { writer in
        try await writer.write("id,title\n")
        for post in try await Post.all() {
            try await writer.write("\(post.id),\(post.title)\n")
        }
    }
}
```

The native server sends each written chunk to the client as it comes, using chunked transfer encoding. On Cloudflare and Lambda, whose response is a single payload, the producer runs to completion and the result is sent whole; the handler code is identical.

The other direction is opted into per route. `body: .streaming` delivers the request body in chunks through `request.bodyReader` instead of buffering it, so a large upload never sits in memory (and the native server's 32 MB buffered-body cap does not apply):

```swift
app.post("/import", body: .streaming) { request in
    var total = 0
    while let chunk = try await request.bodyReader?.next() {
        total += chunk.count   // process incrementally: write to storage, parse, hash…
    }
    return .text("received \(total) bytes")
}
```

On a streaming route `request.body` is empty, so `request.form` (and the CSRF form field) see nothing. Authenticate these endpoints with a bearer token, or send the CSRF token as a header. On buffered targets the handler receives the body as one replayed chunk.

### Flash messages

A flash is a one-time notice carried across a redirect: "Post created" on the page you land on, shown exactly once. Chain `.flash(...)` onto a redirect:

```swift
return .redirect(to: "/posts").flash("Post created")                      // Flash.notice
return .redirect(to: "/posts").flash("Payment failed", kind: Flash.error)
```

The kinds are `Flash.notice`, `.success`, `.error` and `.warning`. The kind doubles as a CSS class for the banner.

The next handler reads the message with `request.flash?.message` and `request.flash?.kind` and passes it into the view. The framework clears the cookie automatically after the page that shows it, so the message appears exactly once.

A flash rides a short-lived (60-second) `plumekit_flash` cookie with no server-side storage, so it works identically on every target. The content is client-visible display text: never put secrets in it.

`generate resource` scaffolds the full loop: created, updated and deleted flashes plus a banner in the Index view.

## Named routes

Hardcoded path strings drift: the route says `/posts/:id`, a redirect elsewhere builds `"/posts/\(id)"`, and renaming the path breaks one of them silently. A named route declares the template once, so you register the handler and build URLs from the same value:

```swift
enum PostRoutes {
    static let index = Route("/posts")
    static let show  = Route1("/posts/:id")
}

app.get(PostRoutes.index) { _ in … }
app.get(PostRoutes.show)  { request in … }

return .redirect(to: PostRoutes.show.path(post.id))   // "/posts/42"
```

`Route` takes no path parameters, `Route1` exactly one and `Route2` exactly two. The parameter count is part of the type, so a missing or extra value in `.path(…)` is a compile error, not a broken URL.

`generate resource` scaffolds a `<Name>Routes` enum and uses it in its redirects.

## Route model binding

The usual preamble of a show, update or destroy action reads `:id`, parses it and calls `find`. With `find(request)`, available on any model, it collapses into one guard:

```swift
app.get(PostRoutes.show) { request in
    guard let post = try await Post.find(request) else { return .status(404) }
    return .text(post.title)
}
```

It reads `request.parameters["id"]` and parses the integer key. Pass `parameter: "post_id"` for nested routes.

Like every ORM lookup, it respects the model's default scope, so a soft-deleted row is not found. See the [ORM](orm.md#soft-deletes).

## Resource controllers

For the conventional RESTful actions of a resource, group them in a `Controller` and wire the routes in one call with `app.resources(_:_:)`:

```swift
app.resources("/api/posts", PostController())
//  GET    /api/posts           → index
//  GET    /api/posts/new       → new
//  POST   /api/posts           → create
//  GET    /api/posts/:id       → show
//  GET    /api/posts/:id/edit  → edit
//  PUT    /api/posts/:id       → update
//  PATCH  /api/posts/:id       → update
//  DELETE /api/posts/:id       → destroy
```

Unimplemented actions fall back to 405. See [Controllers](controllers.md) for the full protocol.

## Route groups

As an application grows, sets of routes start to share a path prefix, middleware or both. `app.group(_:middleware:_:)` registers them together. Group middleware runs after the global stack and only for routes in the group, so it is how you apply middleware to specific routes:

```swift
app.group("/admin", middleware: [requireAdmin]) { admin in
    admin.get("/users") { ... }                 // GET /admin/users, behind requireAdmin
    admin.resources("posts", PostController())  // all behind requireAdmin
}
```

Groups nest. Prefixes compose and middleware accumulates:

```swift
app.group("/api", middleware: [rateLimit]) { api in
    api.group("/v1") { v1 in
        v1.resources("posts", PostController())  // /api/v1/posts, rate-limited
    }
}
```

Global middleware registered with `app.use(...)` still runs for every request. See [Middleware](middleware.md).

## Unmatched requests

Routing distinguishes three outcomes. When the method and path match a route, its handler runs with the captured parameters populated. When the path matches a registered route but no route matches this method, the response is 405 Method Not Allowed. When no route matches the path at all, the response is 404 Not Found.

## Translations

The `localization` middleware resolves the request's language and gives handlers and views a `t("key")` function. See [Translations](i18n.md).
