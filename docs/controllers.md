# Controllers

RESTful resource controllers plus code generators. The controller runtime runs
identically on the native server and the Wasm worker; the generators are CLI
codegen whose output does too.

## Controllers

A `Controller` groups the conventional actions for a resource. `app.resources`
wires the routes; each action has a default `405`, so a controller implements only
what it supports. Dispatch is concrete-generic (`some Controller`).

```swift
struct PostController: Controller {
    func index(_ request: Request) async throws -> Response { … }   // GET    /api/posts
    func new(_ request: Request) async throws -> Response { … }     // GET    /api/posts/new        (create form)
    func create(_ request: Request) async throws -> Response { … }  // POST   /api/posts
    func show(_ request: Request) async throws -> Response { … }    // GET    /api/posts/:id
    func edit(_ request: Request) async throws -> Response { … }    // GET    /api/posts/:id/edit    (edit form)
    func update(_ request: Request) async throws -> Response { … }  // PUT/PATCH /api/posts/:id
    func destroy(_ request: Request) async throws -> Response { … } // DELETE /api/posts/:id
}

app.resources("/api/posts", PostController())
```

The actions compose the pieces already built: route params (`request.parameters`),
the ORM (`Post.find`, `Post.all()`, `save`), and validation (`save` returns
`[ValidationError]` → 422). In `show`/`update`/`destroy`, route model binding turns
the id preamble into one guard:
`guard let post = try await Post.find(request) else { return .status(404) }`
(see [Routing](routing.md#route-model-binding)). The same controller runs on native
SQLite and D1.

### Reading inputs

`request.form` parses a form-urlencoded body, `request.queryParams` the query
string, both with percent-decoding (`%XX`, `+`):

```swift
let title = request.form["title"] ?? ""
let views = request.form.int("views") ?? 0
```

### Testing endpoints without a server

Use `TestHTTPClient` to exercise routes and middleware in process. It builds a
`Request`, calls `Application.handle(_:)` and returns the normal `Response`:

```swift
let app = Application()
app.post("/api/posts") { request in
    .json(.object([(name: "title", value: request.json()?["title"] ?? .null)]), status: 201)
}

let response = await TestHTTPClient(app).post("/api/posts", json: .object([
    (name: "title", value: .string("Hello")),
]))

#expect(response.status == 201)
#expect(response.jsonBody?["title"]?.stringValue == "Hello")
```

Scaffold a controller (or a whole resource) with `plumekit generate controller Post`
/ `plumekit generate resource Post title:string`. See [Generators](generators.md).

## Beyond the seven actions

`resources` wires the standard seven routes. For anything extra (nested resources,
custom member/collection routes), register plain routes alongside it:

```swift
app.resources("posts", PostController())
app.post("/posts/:id/publish") { request in try await PostController().publish(request) }
```
