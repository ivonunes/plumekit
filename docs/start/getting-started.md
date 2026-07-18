# Getting started

PlumeKit is a Swift web framework that runs anywhere. You write an app once as a
library of routes, and the same code runs three ways:

- **natively** on macOS/Linux for local development (`plumekit serve`),
- as a tiny **WebAssembly** module inside a **Cloudflare Worker**
  (`plumekit build --target cloudflare`), and
- as an **AWS Lambda** function behind API Gateway (`plumekit build --target aws`).

Nothing in your app names a platform. Databases, key/value stores, object storage,
queues, secrets, outbound HTTP and mail are reached through *capability bindings*;
a per-target `plumekit.toml` picks which adapter backs each one.

This guide takes you from an empty directory to a running app that serves a route,
reads and writes a database, and deploys to a Worker.

> **Prefer to learn by building?** The [tutorial](tutorial.md) walks through a small,
> complete app (a bookmarks list) step by step. This page is the guided reference.

## Install the CLI

PlumeKit ships a single CLI, `plumekit`, that scaffolds, serves, migrates and
builds your app, and drives the Plume templating toolchain in-process.

```sh
brew install ivonunes/tap/plumekit
# or
curl -fsSL https://install.plumekit.dev | sh
```

Scaffolded projects include a committed **`./plumekit` wrapper** that downloads the
matching CLI release automatically. Once you have a project, you and your CI only
ever run `./plumekit …`; there is no separate install. See the
[CLI reference](../cli.md) for the full command and config surface.

**Toolchain**: a Swift 6 toolchain (6.3.2) is all you need. SQLite is compiled in,
and the first Cloudflare build installs the
[Embedded-Swift WebAssembly SDK](https://www.swift.org/documentation/articles/wasm-getting-started.html)
and fetches `wasm-opt` by itself. Deploys talk to the Cloudflare API directly —
authenticate with `CLOUDFLARE_API_TOKEN`, `plumekit login`, or an active
`wrangler login` session. `plumekit doctor` checks all of it.

(Working from a source checkout instead? `git clone
https://github.com/ivonunes/plumekit.git`, run `swift run plumekit …` and pass
`--path <checkout>` to `plumekit new` so the scaffold depends on the framework by
path.)

## Scaffold a new app

```sh
plumekit new myapp
cd myapp
```

`plumekit new` is **interactive** at a terminal: it asks which capabilities to
enable, your default build target, the database driver, whether to add a Dockerfile
and whether to generate CI. (Press enter to accept the defaults, or pipe/redirect
input for a non-interactive scaffold.)

## Look at the generated project

```txt
myapp/
  Package.swift            # products: Server (native), Worker (Wasm), Lambda (AWS)
  plumekit.toml            # capabilities, [build]/[deploy], per-target drivers
  plumekit                 # the CLI wrapper (commit it; it pins the version)
  Sources/
    App/
      App.swift            # buildApp(): app setup + middleware
      Routes.swift         # registerRoutes(): your routes
      Database/Database.swift  # runMigrations() / runSeed()
      Support/PlumeView.swift  # Response.view(_:) convenience for Plume output
    Server/main.swift      # native entry point for `plumekit serve`
    Worker/main.swift      # Wasm entry point for `plumekit build --target cloudflare`
    Lambda/main.swift      # AWS entry point for `plumekit build --target aws`
  Views/
    Layout.plume           # the shared page shell (a component with a slot)
    HomePage.plume         # a page that fills the layout
  Public/
    app.<hash>.css/js      # the compiled asset bundle (regenerated; gitignored)
```

The generators add directories as you use them: `Models/`, `Controllers/`,
`Middleware/`, `Database/Migrations/` and `Database/Seeders/`.

Files under `Public/` are served as **static files** at their matching URL path
(`Public/images/logo.png` at `/images/logo.png`),
natively by `plumekit serve` and, on the edge, by the platform's own asset serving
(Cloudflare `[assets]`, S3 + CloudFront). Your app references each asset by the same
URL on every target; only *who* serves it changes. The build also drops a
content-hashed Plume bundle (`Public/app.<hash>.css`/`.js`) here, referenced from
templates via `asset("app.css")` / `asset("app.js")`. That bundle is gitignored;
your own files are tracked. See [Portability](../portability.md#static-files-public).

Views are split across files (a shared `Layout` plus one file per page), which
keeps them reusable as the app grows. See [Components](../components/index.md).

The heart of the app is `buildApp()` in `Sources/App/App.swift`. **Both** entry
points call it, so your routes behave identically on the native server and the
Worker:

```swift
import PlumeCore
import PlumeRuntime

public func buildApp() -> Application {
    let app = Application()

    // Middleware: log every request through the platform log seam
    // (console.log on Workers, stdout natively).
    app.use { request, next in
        let response = try await next(request)
        request.context.log("\(request.method.name) \(request.path) -> \(response.status)")
        return response
    }

    // The scaffold's front door renders the styled HomePage view with Plume; see
    // "Rendering views with Plume" below. (`homePage`/`Item` are covered there.)
    app.get("/") { _ in
        .view(homePage(items: [Item(name: "alpha"), Item(name: "beta")]))
    }

    app.get("/hello/:name") { request in
        let name = request.parameters["name"] ?? "world"
        return .text("Hello, \(name)!")
    }

    return app
}
```

## Add a route

Routes are registered with method helpers on `Application`: `get`, `post`, `put`,
`patch`, `delete`, `head`, `options` or `on(_:_:_:)` for an arbitrary method. A
handler is an `async throws` closure from `Request` to `Response`:

```swift
app.post("/echo") { request in
    return .text(request.bodyText)
}

app.get("/greet/:name") { request in
    let name = request.parameters["name"] ?? "world"
    let excited = request.queryParams["excited"] == "true"
    return .text("Hello, \(name)\(excited ? "!" : ".")")
}
```

`:name` captures a path segment into `request.parameters`. The query string is
available parsed via `request.queryParams`. See [Routing](../routing.md) for the
full request and response surface, and [Middleware](../middleware.md) for the
middleware stack.

## Bind a database

Capabilities are opt-in. Open `plumekit.toml` and enable the database capability,
then pick its native driver:

```toml
[capabilities]
kv       = true
database = true          # ← enable it
storage  = false
queue    = false
http     = false
secrets  = false

[targets.native]
database = "sqlite"      # sqlite | postgres

[targets.cloudflare]
database = "d1"          # Cloudflare D1
```

Enabling a capability generates a typed, non-optional accessor on
`request.bindings`. Using a capability you have **not** declared is a *compile*
error; there is no accessor for it.

The database ORM lives in the `PlumeORM` module, so add it to the `App` target in
`Package.swift`:

```swift
.target(
    name: "App",
    dependencies: [
        .product(name: "PlumeCore", package: "PlumeKit"),
        .product(name: "PlumeORM", package: "PlumeKit"),   // ← add this
        .product(name: "PlumeRuntime", package: "PlumeKit"),
    ],
    plugins: [.plugin(name: "PlumeKitCodegen", package: "PlumeKit")]
),
```

Natively, the `sqlite` driver stores the database under `.plumekit/app.db`; on
Cloudflare the same code runs against a bound D1 database. Your app code is
identical either way; the SQL dialect travels with the database handle, not your
routes.

## Define a model

Generate a model, or write one by hand. `@Model` reads your type at compile time
and emits the schema, a row codec and typed query columns:

```sh
plumekit generate model Post title:string body:text published:bool
```

```swift
// Sources/App/Models/Post.swift
import PlumeORM

@Model
final class Post: Model {
    var id: Int              // `id` is the primary key by convention
    var title: String
    var body: String
    var published = false
}
```

Now use it from a handler. Inside a request, ORM calls use the request's database
automatically, with no `in:` to thread through:

```swift
app.get("/posts") { _ in
    let posts = try await Post
        .where(Post.published == true)
        .order(by: Post.id, .descending)
        .all()
    return .text(posts.map(\.title).joined(separator: "\n"))
}

app.post("/posts") { request in
    let post = Post(title: request.form["title"] ?? "", body: request.form["body"] ?? "")
    let errors = try await post.save()          // INSERT; populates post.id
    if !errors.isEmpty { return .text("invalid", status: 422) }
    return .redirect(to: "/posts")
}
```

Outside a request (migrations, seeders, tests) you pass the database explicitly, e.g.
`post.save(in: db)`. See the [ORM](../orm.md) reference for persistence, the typed
query builder and relationships.

A redirect can carry a one-time **flash message**, shown by the next page view and
cleared automatically: `.redirect(to: "/posts").flash("Post created")`. See
[Routing](../routing.md#flash-messages).

## Write and run a migration

Migrations are individual files under `Sources/App/Database/Migrations/`, run in
order and discovered automatically. Scaffold one and describe the change explicitly
with the schema builder:

```sh
plumekit generate migration CreatePosts
```

```swift
import PlumeORM

let createPosts = Migration(
    version: "20260101120000_create_posts",
    up: { db in
        try await db.createTable("posts") { t in
            t.id()
            t.text("title")
            t.text("body")
            t.boolean("published")
        }
    },
    down: { db in try await db.dropTable("posts") }
)
```

Spelling the columns out keeps the migration a frozen record: editing the model
later never rewrites it. Apply it:

```sh
plumekit migrate
#   plumekit migrate: applied 1 change(s)
#     + 20260101120000_create_posts
```

For a Cloudflare D1 database, `plumekit migrate --local` / `--remote` run the same
migrations against it. Seeders work the same way (files under
`Database/Seeders/`, run by `plumekit seed`). See [Migrations](../migrations.md) for
the builder, altering tables and rollbacks.

## Serve it and hit it

```sh
plumekit serve
#   → native server on http://127.0.0.1:8080
```

```sh
curl http://127.0.0.1:8080/                 # the welcome page (HTML)
curl http://127.0.0.1:8080/hello/ada        # Hello, ada!
curl http://127.0.0.1:8080/posts            # your rows
```

While you develop, a thrown error doesn't leave you staring at a bare 500:
`plumekit serve` and `plumekit dev` set `PLUMEKIT_ENV=development`, and the native
server renders a full error page: the error's type and description, the request
and your route table. In production (no env var) the same error is a clean 500;
either way it's logged to stdout.

`plumekit dev` runs the same server but rebuilds and restarts on every source or
template change. `plumekit console` opens an interactive REPL against the same app
and native bindings; type `GET /posts` to dispatch a request without a server, or
`plumekit routes` to list them. `plumekit test` runs your app's test suite, and
`plumekit doctor` checks your toolchain for each target.

## Deploy

The same `buildApp()` ships to a Cloudflare Worker, an AWS Lambda or a container,
whichever target you set as the `default` in `plumekit.toml`'s `[build]`. One command
migrates, builds and deploys:

```sh
plumekit deploy
#   → migrate → build → wrangler deploy   (for the cloudflare target)
```

Or do it by hand: `plumekit build --target cloudflare` compiles your Plume
templates, builds the `Worker` product to Wasm, optimises it with `wasm-opt` and
emits a deployable bundle in `dist/cloudflare/` (the `app.wasm` module, a
dependency-free `worker.mjs` bridging host bindings, and a `wrangler.toml`). The
routes you tested natively now run at the edge, byte-for-byte the same.

Your `wrangler.toml` is yours to customise (bindings, routes, custom domains,
logging); build writes one on first run and reuses your copy afterwards. See
[Deploying](../deploying.md) for the full workflow (Cloudflare, AWS, containers and
CI), and [Portability](../portability.md) for how the targets stay in lockstep.

## Rendering views with Plume

PlumeKit's built-in view layer is **Plume**, a templating language whose `.plume`
files compile to Embedded-Swift render functions. A handler calls the generated
function, which fills an `HTML` buffer, and returns its bytes as the response,
byte-identical natively and on the edge.

The starter project already wires this up. `Views/Layout.plume` is a shared
shell (a component with a `@slot`), and `Views/HomePage.plume` fills it: views
split across files, one per page. `plumekit new`, `serve` and `build` compile them
in-process (the Plume compiler is embedded in the CLI, so there is no separate
install), and the scaffold's `/` handler calls the generated render function:

```swift
app.get("/") { _ in
    let items = [Item(name: "alpha"), Item(name: "Hello & <World>")]
    return .view(homePage(items: items))   // homePage(...) is generated from HomePage.plume
}
```

`{item.name}` is HTML-escaped by default, so `Hello & <World>` renders safely.

`Views/Layout.plume` declares `@navigation(root: "body", viewTransitions: true,
scroll: "top")`, so client-side navigation is on by default. The runtime `<script>`
is injected automatically (you never write a manual `<script src="app.js">`), and
the no-JavaScript full-page-navigation baseline still works. See
[Driving the page](../client/index.md).

For the view-layer integration, see [Plume views in PlumeKit](../plume-views.md).
For the templating language itself (output and expressions, components and slots,
co-located styles/scripts/assets and the tooling) read:

- [Syntax](../syntax/index.md): the language reference.
- [Components](../components/index.md): reusable markup with arguments and slots.
- [Customise](../customise/resources.md): resources and behaviour.
- [Embedding](../embedding/index.md): the Swift render APIs.
- [Tooling](../tooling/index.md): checks, formatting and editor support.
