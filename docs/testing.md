# Testing

PlumeKit apps test natively with [Swift Testing](https://developer.apple.com/documentation/testing).
The scaffold generates a `Tests/AppTests/` target and the **PlumeTesting** module, which
gives each test a fresh, migrated in-memory database, a `TestHTTPClient`, model
factories and response assertions. Run them with:

```sh
plumekit test        # → swift test
```

## The harness

`TestApp.boot` creates a fresh `:memory:` SQLite database, applies your migrations and
binds everything (database, in-memory KV/cache/storage) into a `TestHTTPClient`. Build a
new one per test so state never leaks:

```swift
import Testing
@testable import App
import PlumeTesting   // re-exports PlumeCore + PlumeORM

@Suite struct PostTests {
    @Test func listsPosts() async throws {
        let app = try await TestApp.boot(buildApp, migrations: runMigrations)

        _ = try await Post.factory.create(in: app.database)

        let response = await app.client.get("/posts")
        #expect(response.hasStatus(200))
        #expect(response.bodyContains("Example"))
    }
}
```

`@testable import App` lets tests reach your models and helpers (which are internal to
the App module). `TestApp` exposes `app`, `client`, `database` and `context`.

## The client

`app.client` is a `TestHTTPClient`: it dispatches requests through your app in-process
(no sockets):

```swift
await app.client.get("/posts")
await app.postForm("/posts", [("title", "Hello"), ("body", "World & more")])
await app.client.post("/api/posts", json: .object([(name: "title", value: .string("Hi"))]))
await app.client.get("/me", headers: .bearer(token))          // authenticated request
```

`app.postForm` percent-encodes the fields and appends the harness's CSRF token,
so a controller test is just the fields it cares about. The lower-level
`app.client.postForm(_:fields:)` encodes without the token, and the raw string
form (`app.client.postForm("/posts", "a=b")`) is still there for testing
malformed bodies.

## Response assertions

Convenience checks that read well inside `#expect`:

```swift
#expect(response.hasStatus(201))
#expect(response.isOK)             // 200
#expect(response.isSuccessful)     // 2xx
#expect(response.isRedirect)       // 3xx
#expect(response.bodyContains("created"))
#expect(response.header("content-type")?.contains("json") == true)
#expect(response.redirectLocation == "/posts")
if let json = response.decodedJSON() { … }
```

## Factories

Define a `Factory` on a model: a builder for test (and seed) data. Factories live in
`Sources/App/Database/Factories/` and work in both seeders and tests:

```swift
extension Post {
    static let factory = Factory { Post(title: "Example", views: 0) }
}
```

```swift
let post  = try await Post.factory.create(in: db)                    // INSERT, id populated
let draft = Post.factory.make()                                      // unsaved instance
let hot   = try await Post.factory.create(in: db) { $0.views = 999 } // with overrides
let many  = try await Post.factory.createMany(3, in: db) { i, p in p.title = "Post \(i)" }
```

### Unique / random values with `Fake`

For unique columns, use `Fake` (unique-ish random values) instead of static defaults:

```swift
extension User {
    static let factory = Factory { User(email: Fake.email(), passwordHash: "x") }
}
```

`Fake.int(in:)`, `Fake.string(length:)`, `Fake.hex(_:)`, `Fake.email()`, `Fake.bool()`,
`Fake.words(_:)`. Like factories, `Fake` runs on
every target, so seeders that use it are portable.

## Testing auth

Auth resolves the same from a cookie or a bearer token, so a test can log in and reuse
the token as a bearer:

```swift
@Test func meRequiresAuth() async throws {
    let app = try await TestApp.boot(buildApp, migrations: runMigrations)

    // register → the JSON response carries a token
    let registered = await app.client.post("/register", json: .object([
        (name: "email", value: .string("a@b.com")),
        (name: "password", value: .string("secret123")),
    ]))
    let token = registered.decodedJSON()?["token"]?.stringValue ?? ""

    let me = await app.client.get("/me", headers: .bearer(token))
    #expect(me.isOK)
}
```

## Generating tests

- `plumekit generate test <Name>` scaffolds `Tests/AppTests/<Name>Tests.swift`.
- `plumekit generate resource <Name> …` also emits a **factory** and a **test** for the
  resource, which pass out of the box once the route and migration are wired.

See [Generators](generators.md).
