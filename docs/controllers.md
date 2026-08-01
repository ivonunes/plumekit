# Controllers

A controller groups the conventional RESTful actions for a resource in one type, instead of scattering them across standalone route closures. The controller runtime runs identically on the native server and the Cloudflare Worker, and the CLI can generate controllers whose output does too.

## The Controller protocol

A `Controller` declares the seven conventional actions. Each action has a default 405 response, so a controller implements only what it supports. Dispatch is concrete-generic (`some Controller`).

Define the actions you need, then wire the routes in one call with `app.resources`:

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

`resources` registers this route map:

| Method | Path | Action | Purpose |
|---|---|---|---|
| `GET` | `/api/posts` | `index` | List the resource |
| `GET` | `/api/posts/new` | `new` | Form to create one |
| `POST` | `/api/posts` | `create` | Create one |
| `GET` | `/api/posts/:id` | `show` | Show one |
| `GET` | `/api/posts/:id/edit` | `edit` | Form to edit one |
| `PUT` / `PATCH` | `/api/posts/:id` | `update` | Update one |
| `DELETE` | `/api/posts/:id` | `destroy` | Delete one |

## Inside an action

Actions compose the pieces the rest of the framework already provides: route parameters (`request.parameters`), the ORM (`Post.find`, `Post.all()`, `save`) and validation (`save` returns `[ValidationError]`, which a failing action turns into a 422). The same controller runs on native SQLite and D1.

In `show`, `update` and `destroy`, route model binding turns the id preamble into one guard:

```swift
guard let post = try await Post.find(request) else { return .status(404) }
```

See [Routing](routing.md#route-model-binding).

### Reading inputs

`request.form` parses a form-urlencoded body and `request.queryParams` the query string, both with percent-decoding (`%XX`, `+`):

```swift
let title = request.form["title"] ?? ""
let views = request.form.int("views") ?? 0
```

## Beyond the seven actions

`resources` wires the standard seven actions and nothing else. For anything extra, such as nested resources or custom member and collection routes, register plain routes alongside it:

```swift
app.resources("posts", PostController())
app.post("/posts/:id/publish") { request in try await PostController().publish(request) }
```

## Generating controllers

Scaffold a controller, or a whole resource with model, views and routes, from the CLI:

```sh
plumekit generate controller Post
plumekit generate resource Post title:string
```

See [Generators](generators.md).

## Testing endpoints without a server

Use `TestHTTPClient` to exercise routes and middleware in process. It builds a `Request`, calls `Application.handle(_:)` and returns the normal `Response`:

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
