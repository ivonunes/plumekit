# Routing

PlumeKit routes an HTTP method and a path to a handler. Routing is deliberately
simple and allocation-light: a flat route table matched by comparing pre-parsed
path segments as UTF-8 bytes, with no regex and no Foundation, so it runs
identically on the native server and the Cloudflare Worker.

## Registering routes

Register handlers on the `Application` you build in `buildApp()`. There is a helper
per method, plus `on(_:_:_:)` for an arbitrary method:

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

The supported methods are `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, and
`OPTIONS`.

## Handlers

A handler is a `Responder`, an `async throws` closure from a `Request` to a
`Response`:

```swift
public typealias Responder = (Request) async throws -> Response
```

`async` lets a handler `await` host bindings (a KV read, a SQL query); a synchronous
handler is just a closure that never awaits. A thrown error is caught by the
framework and returned as a 500, so handlers can `try` freely:

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

The error is always logged to stdout. Under `plumekit serve` / `plumekit dev`
(which set `PLUMEKIT_ENV=development`), the native server renders a **dev error
page** instead of the bare 500: the error's type and description, the request
(method, path, query, headers, a body preview), and the app's route table. In
production (no env var) it stays a clean 500. The page is native-only by design;
the Wasm guest can't stringify errors.

## Path parameters

A segment written `:name` captures that segment. Captured values are read from
`request.parameters`, which returns `String?`:

```swift
app.get("/users/:userID/posts/:postID") { request in
    let userID = request.parameters["userID"] ?? ""
    let postID = request.parameters["postID"] ?? ""
    return .text("user \(userID), post \(postID)")
}
```

Matching is exact per segment. Empty path segments are ignored, so a trailing slash
does not change matching (`/posts` and `/posts/` match the same route).

### Wildcards (catch-all)

A `*name` segment (which must be last) captures the rest of the path (one or more
segments, slash-joined) into `request.parameters["name"]`:

```swift
app.get("/files/*path") { request in
    request.parameters["path"]     // "/files/a/b/c.txt" → "a/b/c.txt"
}
```

`*name` requires at least one trailing segment; `**name` also matches zero, so
`/assets/**path` matches the bare `/assets` too. (Regex patterns are not
supported; a regex engine isn't linkable in the Wasm guest. Validate a captured
segment in the handler instead.)

## Named routes

Hardcoded path strings drift: the route says `/posts/:id`, a redirect elsewhere
builds `"/posts/\(id)"`, and renaming the path breaks one of them silently. A named
route declares the template once; you both register the handler and build URLs
from the same value:

```swift
enum PostRoutes {
    static let index = Route("/posts")
    static let show  = Route1("/posts/:id")
}

app.get(PostRoutes.index) { _ in … }
app.get(PostRoutes.show)  { request in … }

return .redirect(to: PostRoutes.show.path(post.id))   // "/posts/42"
```

`Route` takes no path parameters, `Route1` exactly one, `Route2` exactly two. The
parameter count is part of the type, so a missing or extra value in `.path(…)` is a
**compile error**, not a broken URL. `generate resource` scaffolds a `<Name>Routes`
enum and uses it in its redirects.

## Route model binding

The show/update/destroy preamble (read `:id`, parse it, `find`) collapses into
one guard with `find(request)` on any model:

```swift
app.get(PostRoutes.show) { request in
    guard let post = try await Post.find(request) else { return .status(404) }
    return .text(post.title)
}
```

It reads `request.parameters["id"]` and parses the integer key; pass
`parameter: "post_id"` for nested routes. Like every ORM lookup, it respects the
model's default scope, so a soft-deleted row is not found. See the
[ORM](orm.md#soft-deletes).

## Query parameters

The raw query string is available as `request.query`, and parsed as
`request.queryParams` (a `FormParams`, with `%XX` and `+` decoding):

```swift
app.get("/search") { request in
    let term = request.queryParams["q"] ?? ""
    let page = request.queryParams.int("page") ?? 1
    return .text("q=\(term) page=\(page)")
}
```

## Match outcomes

Routing distinguishes three cases:

- **Found**: the method and path match a route; its handler runs with the captured
  parameters populated.
- **Method not allowed**: the path matches a registered route but no route matches
  this method → **405 Method Not Allowed**.
- **Not found**: no route matches the path → **404 Not Found**.

## The Request

A handler receives an immutable `Request` value (the router populates its
`parameters` before dispatch):

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

Bindings are reached through `request.bindings` (typed, non-optional, generated from
the capabilities you declare in `plumekit.toml`) or `request.context` (optional). See
[Bindings & drivers](bindings.md).

## The Response

Build responses with `Response`'s convenience constructors, or the initializer for
full control:

```swift
.text("hello")                         // text/plain; charset=utf-8
.text("nope", status: 404)
.html("<h1>hi</h1>")                    // text/html; charset=utf-8
.html(bytes: renderedHTML)             // pre-rendered UTF-8 bytes (e.g. Plume)
.json("{\"ok\":true}")                 // pre-serialized JSON string
.json(.object([("ok", .bool(true))]))  // from a JSONValue
.status(204)                           // bare status, empty body
.redirect(to: "/posts")               // 303 See Other by default

Response(status: 201, headers: headers, body: bytes)   // full control
```

`Response` exposes `status`, `headers`, `body` (`[UInt8]`), `bodyText`, and
`reasonPhrase`. Set headers before returning:

```swift
var response = Response.text("created", status: 201)
response.headers.set("location", "/posts/42")
return response
```

### Flash messages

A flash is a one-time notice carried across a redirect: "Post created" on the page
you land on, shown exactly once:

```swift
return .redirect(to: "/posts").flash("Post created")                      // Flash.notice
return .redirect(to: "/posts").flash("Payment failed", kind: Flash.error)
```

Kinds: `Flash.notice`, `.success`, `.error`, `.warning`. The kind doubles as a CSS
class for the banner. The next handler reads it with `request.flash?.message` /
`?.kind` and passes it into the view; the framework clears the cookie automatically
after the page that shows it, so the message appears exactly once. It rides a
short-lived (60-second) `plumekit_flash` cookie with no server-side storage, so it
works identically on every target. The content is client-visible display text:
never put secrets in it. `generate resource` scaffolds the full loop
(created/updated/deleted flashes plus a banner in the Index view).

## Resource controllers

For the conventional RESTful actions of a resource, group them in a `Controller` and
wire the routes in one call with `app.resources(_:_:)`:

```swift
app.resources("/api/posts", PostController())
//  GET    /api/posts        → index
//  POST   /api/posts        → create
//  GET    /api/posts/:id    → show
//  PUT    /api/posts/:id    → update
//  PATCH  /api/posts/:id    → update
//  DELETE /api/posts/:id    → destroy
```

Unimplemented actions fall back to 405. See [Controllers](controllers.md) for the
full protocol.

## Groups and scoped middleware

`app.group(_:middleware:_:)` registers a set of routes that share a path prefix and/or
middleware. Group middleware runs after the global stack and **only** for routes in the
group, so it's how you apply middleware to specific routes:

```swift
app.group("/admin", middleware: [requireAdmin]) { admin in
    admin.get("/users") { ... }                 // GET /admin/users, behind requireAdmin
    admin.resources("posts", PostController())  // all behind requireAdmin
}
```

Groups nest; prefixes compose and middleware accumulates:

```swift
app.group("/api", middleware: [rateLimit]) { api in
    api.group("/v1") { v1 in
        v1.resources("posts", PostController())  // /api/v1/posts, rate-limited
    }
}
```

Global middleware registered with `app.use(...)` still runs for every request; see
[middleware](middleware.md).

## Translations

The `localization` middleware resolves the request's language and gives handlers and
views a `t("key")` function. See [Translations](i18n.md).
