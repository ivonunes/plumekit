# Getting started

PlumeKit is a web framework for Swift. You write your app once, as a library of routes, and the same code runs natively on a server, on Cloudflare Workers and on AWS Lambda. This guide takes you from an empty directory to a running app that serves a route, reads and writes a database and deploys to a Worker.

In this guide you will learn:

- How to install the `plumekit` CLI and scaffold a new app
- How the generated project fits together
- How to add routes and handle requests
- How to enable a database, define a model and run a migration
- How to serve the app locally and render HTML with Plume views
- How to deploy the same app to the edge

> **Tip:** Prefer to learn by building? The [tutorial](tutorial.md) walks through a small, complete app (a bookmarks list) step by step. This page is the guided reference.

## One app, three targets

Nothing in a PlumeKit app names a platform. The same code runs three ways:

- **Natively** on macOS or Linux for local development (`plumekit serve`)
- As a tiny **WebAssembly** module inside a **Cloudflare Worker** (`plumekit build --target cloudflare`)
- As an **AWS Lambda** function behind API Gateway (`plumekit build --target aws`)

Databases, key/value stores, object storage, queues, secrets, outbound HTTP and mail are reached through *capability bindings*. A per-target `plumekit.toml` picks which adapter backs each one. See [Concepts](concepts.md) for the mental model behind this.

## Installing the CLI

PlumeKit ships a single CLI, `plumekit`. It scaffolds, serves, migrates and builds your app, and drives the Plume templating toolchain in-process. Install it with Homebrew or the install script:

```sh
brew install ivonunes/tap/plumekit
# or
curl -fsSL https://install.plumekit.dev | sh
```

You need this install only to scaffold your first project. Scaffolded projects include a committed **`./plumekit` wrapper** that downloads the matching CLI release automatically, so once you have a project, you and your CI only ever run `./plumekit …`; there is no separate install. See [CLI & configuration](../cli.md) for the full command and config surface.

Beyond that, a Swift 6 toolchain (6.3.2) is all you need. SQLite is compiled in, and the first Cloudflare build installs the [Embedded-Swift WebAssembly SDK](https://www.swift.org/documentation/articles/wasm-getting-started.html) and fetches `wasm-opt` by itself. Deploys talk to the Cloudflare API directly: authenticate with `CLOUDFLARE_API_TOKEN`, `plumekit login`, or an active `wrangler login` session. `plumekit doctor` checks all of it.

> **Note:** Working from a source checkout instead? Run `git clone https://github.com/ivonunes/plumekit.git`, use `swift run plumekit …` and pass `--path <checkout>` to `plumekit new` so the scaffold depends on the framework by path.

## Scaffolding a new app

Create a project and step into it:

```sh
plumekit new myapp
cd myapp
```

`plumekit new` is **interactive** at a terminal: it asks which capabilities to enable, your default build target, the database driver, whether to add a Dockerfile and whether to generate CI. Press enter to accept the defaults, or pipe/redirect input for a non-interactive scaffold.

## The generated project

Here is what the scaffold gives you:

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

The generators add directories as you use them: `Models/`, `Controllers/`, `Middleware/`, `Database/Migrations/` and `Database/Seeders/`.

### Static files

Files under `Public/` are served as **static files** at their matching URL path (`Public/images/logo.png` at `/images/logo.png`). Natively, `plumekit serve` serves them; on the edge, the platform's own asset serving does (Cloudflare `[assets]`, S3 + CloudFront). Your app references each asset by the same URL on every target; only *who* serves it changes.

The build also drops a content-hashed Plume bundle (`Public/app.<hash>.css`/`.js`) here, referenced from templates via `asset("app.css")` / `asset("app.js")`. That bundle is gitignored; your own files are tracked. See [Portability](../portability.md#static-files-public).

### Views

Views are split across files (a shared `Layout` plus one file per page), which keeps them reusable as the app grows. See [Components](../components/index.md).

### The application entry point

The heart of the app is `buildApp()` in `Sources/App/App.swift`. **Both** entry points call it, so your routes behave identically on the native server and the Worker. `App.swift` sets up the middleware (logging, method override, CSRF, localisation) and calls `registerRoutes(app)`.

Your routes live in `Sources/App/Routes.swift`:

```swift
// Sources/App/Routes.swift
func registerRoutes(_ app: Application) {
    // The front door: the welcome page, a Plume-rendered view.
    app.get("/") { _ in
        .view(homePage())
    }

    // Path parameters bind by name:
    app.get("/hello/:name") { request in
        let name = request.parameters["name"] ?? "world"
        return .text("Hello, \(name)!")
    }
}
```

## Adding routes

Routes are registered with method helpers on `Application`: `get`, `post`, `put`, `patch`, `delete`, `head`, `options` or `on(_:_:_:)` for an arbitrary method. A handler is an `async throws` closure from `Request` to `Response`:

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

`:name` captures a path segment into `request.parameters`. The query string is available parsed via `request.queryParams`.

See [Routing](../routing.md) for the full request and response surface, and [Middleware](../middleware.md) for the middleware stack.

## Enabling a database

Capabilities are opt-in. Open `plumekit.toml`, enable the database capability and pick its native driver:

```toml
[capabilities]
kv       = true
database = true          # ← enable it
storage  = false
cache    = false
queue    = false
http     = false
secrets  = false

[targets.native]
database = "sqlite"      # sqlite | postgres

[targets.cloudflare]
database = "d1"          # Cloudflare D1
```

Enabling a capability generates a typed, non-optional accessor on `request.bindings`. Using a capability you have **not** declared is a *compile* error; there is no accessor for it.

The database ORM lives in the `PlumeORM` module. The scaffold's `App` target already depends on it, so `import PlumeORM` just works.

Natively, the `sqlite` driver stores the database under `.plumekit/app.db`. On Cloudflare, the same code runs against a bound D1 database. Your app code is identical either way; the SQL dialect travels with the database handle, not your routes.

## Defining a model

Generate a model, or write one by hand:

```sh
plumekit generate model Post title:string body:text published:bool
```

`@Model` reads your type at compile time and emits the schema, a row codec and typed query columns:

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

### Using the model in a handler

Now use the model from a handler. Inside a request, ORM calls use the request's database automatically (the [ambient database](../orm.md#the-ambient-database)), with no `in:` to thread through:

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

Outside a request (migrations, seeders, tests) you pass the database explicitly, for example `post.save(in: db)`. See the [ORM](../orm.md) reference for persistence, the typed query builder and relationships.

A redirect can carry a one-time **flash message**, shown by the next page view and cleared automatically: `.redirect(to: "/posts").flash("Post created")`. See [Routing](../routing.md#flash-messages).

## Writing a migration

The `posts` table does not exist yet; a migration creates it. Migrations are individual files under `Sources/App/Database/Migrations/`, run in order and discovered automatically. Scaffold one:

```sh
plumekit generate migration CreatePosts
```

Then describe the change explicitly with the schema builder:

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

Spelling the columns out keeps the migration a frozen record: editing the model later never rewrites it.

### Running migrations

Apply the migration:

```sh
plumekit migrate
#   plumekit migrate: applied 1 change(s)
#     + 20260101120000_create_posts
```

For a Cloudflare D1 database, `plumekit migrate --local` / `--remote` run the same migrations against it. Seeders work the same way: files under `Database/Seeders/`, run by `plumekit seed`.

See [Migrations](../migrations.md) for the builder, altering tables and rollbacks.

## Serving the app

Start the native server:

```sh
plumekit serve
#   → native server on http://127.0.0.1:8080
```

Then hit it:

```sh
curl http://127.0.0.1:8080/                 # the welcome page (HTML)
curl http://127.0.0.1:8080/hello/ada        # Hello, ada!
curl http://127.0.0.1:8080/posts            # your rows
```

### Errors in development

While you develop, a thrown error does not leave you staring at a bare 500: the native server renders a full error page with the error, the request and your route table. In production the same error is a clean 500. See [the development error page](../routing.md#the-development-error-page).

### Development commands

`plumekit dev` runs the same server but rebuilds and restarts on every source or template change. `plumekit console` opens an interactive REPL against the same app and native bindings; type `GET /posts` to dispatch a request without a server. `plumekit routes` lists your routes, `plumekit test` runs your app's test suite and `plumekit doctor` checks your toolchain for each target.

## Rendering views with Plume

PlumeKit's built-in view layer is **Plume**, a templating language whose `.plume` files compile to Embedded-Swift render functions. A handler calls the generated function, which fills an `HTML` buffer, and returns its bytes as the response, byte-identical natively and on the edge.

The starter project already wires this up. `Views/Layout.plume` is a shared shell (a component with a `@slot`) and `Views/HomePage.plume` fills it: views split across files, one per page. `plumekit new`, `serve` and `build` compile them in-process (the Plume compiler is embedded in the CLI, so there is no separate install), and the scaffold's `/` handler calls the generated render function:

```swift
app.get("/") { _ in
    .view(homePage())   // homePage(into:) is generated from HomePage.plume
}
```

Dynamic values in a template (`{title}` and friends) are HTML-escaped by default, so `Hello & <World>` renders safely.

### Client-side navigation

`Views/Layout.plume` declares `@navigation(root: "body", viewTransitions: true, scroll: "top")`, so client-side navigation is on by default. The runtime `<script>` is injected automatically (you never write a manual `<script src="app.js">`), and the no-JavaScript full-page-navigation baseline still works. See [Driving the page](../client/index.md).

### Learning the language

For the view-layer integration, see [Plume views in PlumeKit](../plume-views.md). For the templating language itself (output and expressions, components and slots, co-located styles/scripts/assets and the tooling) read:

- [Syntax](../syntax/index.md): the language reference
- [Components](../components/index.md): reusable markup with arguments and slots
- [Customise](../customise/resources.md): resources and behaviour
- [Embedding](../embedding/index.md): the Swift render APIs
- [Tooling](../tooling/index.md): checks, formatting and editor support

## Deploying

The same `buildApp()` ships to a Cloudflare Worker, an AWS Lambda or a container, whichever target you set as the `default` in `plumekit.toml`'s `[build]`. One command migrates, builds and deploys:

```sh
plumekit deploy
#   → migrate → build → wrangler deploy   (for the cloudflare target)
```

Or do it by hand: `plumekit build --target cloudflare` compiles your Plume templates, builds the `Worker` product to Wasm, optimises it with `wasm-opt` and emits a deployable bundle in `dist/cloudflare/` (the `app.wasm` module, a dependency-free `worker.mjs` bridging host bindings, and a `wrangler.toml`). The routes you tested natively now run at the edge, byte-for-byte the same.

> **Warning:** `dist/cloudflare/wrangler.toml` is generated from `plumekit.toml` on every build, so don't edit it in place. Change `plumekit.toml` (capabilities, bindings, database name) and rebuild.

See [Deploying](../deploying.md) for the full workflow (Cloudflare, AWS, containers and CI), and [Portability](../portability.md) for how the targets stay in lockstep.
