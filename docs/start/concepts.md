# Concepts

PlumeKit has one governing idea: **write the app once, run it on any target.**
Everything else (the module layout, the capability bindings, the request
lifecycle) exists to make that literally true, with no platform branches in your
code. This page is the mental model; the feature docs are the detail.

## One portable core, many adapters

PlumeKit is split into a platform-agnostic core and thin per-platform adapters.

- **`PlumeCore`** is the framework core: routing, request/response, middleware, the
  capability seam, auth, and the API surface. It uses no Foundation and no
  runtime reflection (bytes are `[UInt8]`), so it compiles to a tiny WebAssembly
  module as readily as it does a native binary.
- **`PlumeORM`** is the `@Model` macro, the row codec, the typed
  query builder, and the migrator. It also compiles to Wasm, and it talks only to
  the SQL capability, so a model runs unchanged on native SQLite, Postgres, and
  Cloudflare D1.
- **`PlumeServer`** is the native adapter: a SwiftNIO HTTP/1.1 server, the native
  binding drivers (SQLite, filesystem object storage, in-process queue, and so on), the
  `plumekit serve` runtime, and the interactive console.
- **`PlumeWorker`** is the Cloudflare adapter: the Wasm byte marshalling and the
  async host-binding bridge that lets the module call Cloudflare's KV, D1, R2, and
  queues.
- **`Plume`** / **`PlumeRuntime`** are the templating language: the compiler and the
  render runtime. They are one component of the framework, not its
  center, and are usable on their own.

Your app is a library of routes plus two thin entry points. Both entry points call
the same `buildApp()`:

```
                 Sources/App/  ── buildApp() ──▶  Application (routes + middleware)
                      │                                  │
        ┌─────────────┴─────────────┐        ┌───────────┴────────────┐
   Sources/Server/main.swift   Sources/Worker/main.swift
   PlumeServer (native NIO)     PlumeWorker (Wasm + JSPI)
   `plumekit serve`             `plumekit build --target cloudflare`
```

The core knows nothing about NIO or Cloudflare. An adapter decodes a transport
request into a `Request`, calls `Application.handle(_:)`, and serializes the
returned `Response` back onto the wire.

## The capability seam

Your handlers never name a platform type: no `env`, no `D1Database`, no
`KVNamespace`. Instead they reach host services through **capability bindings**:
small concrete structs of async closures carried on each request's `Context` (KV,
database, storage, queue, HTTP client, secrets, mailer, broadcaster, and a log
function). Each capability is a protocol (the *adapter contract*) plus a concrete
handle that wraps any conforming adapter via an opaque `some` generic.

Which adapter backs each capability is decided at the **composition root**, driven
by a per-project `plumekit.toml`:

```toml
[capabilities]           # which capabilities this app uses
kv       = true
database = true

[targets.native]                 # native driver selection
database = "sqlite"      # sqlite | postgres

[targets.cloudflare]             # Cloudflare adapter selection
database = "d1"
```

A build-tool plugin regenerates two files from this manifest on every build:

- **`Bindings.swift`**: a typed `request.bindings` view exposing exactly the
  capabilities you declared. Reaching for one you did not declare is a *compile*
  error, because no accessor is generated for it.
- **`Composition.swift`**: the native composition root that wires the selected
  drivers into a `Context` for `plumekit serve`.

Changing a driver is a one-line edit to `plumekit.toml` and a rebuild. No app-code
change, no platform conditional. On Cloudflare the bindings are configured in
`wrangler.toml` and bridged in by the generated Worker glue.

## The request lifecycle

A request flows through the middleware stack, into a matched route, and back out as
a response:

```
Request ─▶ middleware₀ ─▶ middleware₁ ─▶ … ─▶ route handler ─▶ Response
             (each may short-circuit or transform on the way out)
```

- **Routing** matches an HTTP method and a path pattern (with `:name` path
  parameters). No match is a 404; a path that exists for another method is a 405.
- **Middleware** is a function `(Request, next) async throws -> Response`.
  Registration order is nesting order: the first-registered middleware is outermost.
  A middleware may inspect or rewrite the request, call `next` to continue, or return
  early to short-circuit.
- **Handlers** are `async throws` closures. `async` is what lets a handler `await` a
  host binding (a KV read, a SQL query); a thrown error becomes a 500.

The same `Request` and `Response` value types are used everywhere. Bodies are
`[UInt8]`; convenience constructors (`.text`, `.html`, `.json`, `.redirect`) cover
the common cases. See [Routing](../routing.md) and [Middleware](../middleware.md).

## Async, natively and as Wasm

Handlers are `async` because host bindings are asynchronous on every target. On the
native server, an `await` on a binding calls an in-process driver. On Cloudflare,
the same `await` suspends the WebAssembly stack across the boundary to the JS host
(via JSPI) while Cloudflare fetches from KV/D1/R2, then resumes the module. Your
code is identical; only the adapter behind the closure differs.

## Plume is one component

Plume, the templating language, is PlumeKit's built-in view layer, but it is not
the framework's core. A `.plume` file compiles to a render function
that writes HTML into a buffer; a handler calls it and returns the bytes as a
response. The core stays view-engine-agnostic: it only ever sees `[UInt8]`. Because
the language is a standalone module, an external static-site generator can use
Plume without any of the web framework. See [Plume views in
PlumeKit](../plume-views.md).

## Where to go next

- [Getting started](getting-started.md): build and run an app end to end.
- [Bindings & drivers](../bindings.md): the full capability catalogue and driver
  selection.
- [Portability](../portability.md): how one app targets both runtimes.
