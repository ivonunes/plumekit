# Bindings & the capability model

PlumeKit is **platform-neutral**: core and app code depend only on capability
protocols and never name a platform type (`env`, `D1`, `R2`, `KVNamespace`…).
Cloudflare is one adapter set, the native server is a real, deployable second one,
and AWS (S3/SQS/SSM/DynamoDB/SES + RDS Postgres, on Lambda) is a third. See
[Deploying to AWS Lambda](aws.md).

## The pattern

Each capability is a **protocol** (the adapter contract) plus a concrete
**handle** carried in `Request.context`. The handle wraps any conforming adapter
via an opaque `some` generic, so it compiles in the Wasm build too:

```swift
public protocol SQLDatabase: DataStore {           // adapter contract
    func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult
}

public struct Database: Sendable {                 // handle in Context
    public init(_ adapter: some SQLDatabase) { … }  // `some`, not `any`
    public func query(…) async throws -> QueryResult { … }
}
```

Inside a handler, reach each capability **ambiently**, with no `request` to thread
through. The framework binds the current request's capabilities, so ORM calls use
the request's database (`Post.all()`), and every other capability has a `.current`
accessor:

```swift
app.get("/counter") { _ in
    let kv = KV.current                      // the request's KV binding
    let n = (await kv.getString("hits")).flatMap { Int($0) } ?? 0
    await kv.putString("hits", String(n + 1))
    return .text("\(n + 1)")
}
```

`Database.current`, `KV.current`, `Cache.current`, `Storage.current`, `Queue.current`,
`Secrets.current`, `HTTP.current`, `Mailer.current`: each returns the request's binding
(and traps with a clear message if the capability isn't enabled or you're outside a
request).

There's also a generated, typed view, `request.bindings`, with **non-optional**
accessors for exactly the capabilities declared in `plumekit.toml`, so using one you
didn't declare is a *compile* error rather than a runtime trap:

```swift
app.get("/posts") { request in
    let db = request.bindings.database   // non-optional; exists iff declared
    let rows = try await db.query("SELECT id, title FROM posts ORDER BY id")
    …
}
```

See [Capability presence is a compile-time gate](#capability-presence-is-a-compile-time-gate).

## Capabilities and adapters (so far)

| Capability  | Protocol      | Cloudflare adapter (wasm, JSPI) | Native adapter            | AWS adapter               |
| ----------- | ------------- | ------------------------------- | ------------------------- | ------------------------- |
| KV          | `KV` (struct) | Workers KV                      | file / in-memory          | **DynamoDB**              |
| Cache       | `Cache` (struct) | Workers KV (`expirationTtl`) | in-memory TTL           | **DynamoDB** (table TTL)  |
| SQL         | `SQLDatabase` | **D1**                          | **SQLite** / **Postgres** | **RDS Postgres**          |
| Object storage | `StorageDriver` | **R2**                       | **filesystem** / memory / **S3** | **S3**             |
| Queue       | `MessageQueue`| **Queues** (producer)           | **in-process**            | **SQS**                   |
| HTTP/fetch  | `HTTPClient`  | global **fetch**                | **URLSession**            | **URLSession**            |
| Secrets     | `SecretStore` | secrets/vars on **`env`**       | **environment variables** | **SSM Parameter Store**  |
| Mailer      | `Mailer`      | Cloudflare adapter              | log / SMTP                | **SES**                   |
| Channels    | `Channel`     | **Durable Object**              | long-lived actor          | **API Gateway** (+ DynamoDB) |
| Logging     | (closure)     | `console.log`                   | stdout                    | stdout (CloudWatch)       |

The same handler runs against D1, SQLite and RDS Postgres; against R2, the
filesystem and S3; natively (`plumekit serve`), on `wrangler dev` and as a
`provided.al2` Lambda. Each adapter conforms to the same protocol; nothing in the
core or app names a platform type.

## Selection (compile-time) vs config (runtime)

- **Selection** of an adapter set is **compile-time, manifest-driven**. A
  `plumekit.toml` (see [the CLI & config reference](cli.md)) declares the per-target
  drivers; the build generates the native composition root from it on every
  `swift build`, with no committed generated code:

  ```toml
  [targets.native]
  database = "sqlite"      # sqlite | postgres
  storage  = "filesystem"  # filesystem | memory | s3
  ```

  Editing a value + rebuilding relinks a different adapter set with **zero
  app-code change**: flip `storage` to `memory` and stored blobs are served
  from memory (no disk file), with only the manifest changed. The Cloudflare
  adapters (D1/R2/KV) are wired in the Wasm worker composition and configured via
  `wrangler.toml`.
- **Config** (connection strings, secrets, paths) is **runtime**, via a neutral
  provider. It is never a compiled-in value and never a direct `env` read in app code.

### Secrets

That neutral provider is the **Secrets** capability. A handler asks for a named
secret and gets bytes (or nil); it never touches `env`:

```swift
app.get("/config/:name") { request in
    let isSet = try await request.bindings.secrets.has(request.parameters["name"]!)
    return .text(isSet ? "set" : "unset")   // presence only; never echo a value
}
```

Adapters: native reads **process environment variables** (`plumekit serve` with
`API_TOKEN=…`); Cloudflare reads secrets/vars from the Worker **`env`** (a `[vars]`
entry in `wrangler.toml`) through a synchronous, non-JSPI host bridge. The same
handler works on both. The API is `async` because a backend may be remote (a
vault); the env adapters return without suspending.

### Cache

**Cache** is an ephemeral, TTL'd key/value store, **best-effort by design**. A
`get` may miss at any time (an entry can expire or be evicted), so a handler
treats `nil` as "recompute", never as "gone for good":

```swift
app.get("/render/:id") { request in
    let key = "render:" + request.parameters["id"]!
    if let cached = try await request.bindings.cache.getString(key) {
        return .text(cached)                                 // fast path
    }
    let fresh = expensiveRender()                            // miss → recompute
    try await request.bindings.cache.setString(key, fresh, ttlSeconds: 300)
    return .text(fresh)
}
```

The `Cache` handle exposes `get(_:) async throws -> [UInt8]?`,
`set(_:_:ttlSeconds:) async throws` (a `nil` TTL means "no explicit expiry") and
`delete(_:) async throws`, plus the UTF-8 convenience pair
`getString`/`setString(_:_:ttlSeconds:)`. Declare it with `cache = true` under
`[capabilities]` and select a driver in `plumekit.toml` (`cache = "..."`). The
native adapter is an in-memory TTL cache (`NativeDrivers.memoryCache()`);
Cloudflare backs it with a Workers KV namespace used as a cache, passing the TTL
through as `expirationTtl` (bound as `CACHE` in `wrangler.toml`).

Cache is the deliberate counterpart to **KV**, which is *durable* and has no TTL:
reach for **KV** when a write must be readable back later, and for **Cache** when
a miss is always survivable (memoisation, rendered fragments, rate-limit windows).

### Opt-in Postgres

`PlumePostgres` (a native `libpq` driver) is a separate product so SQLite-only apps
never need libpq. Select it in `plumekit.toml` (`database = "postgres"`) and add
`.product(name: "PlumePostgres", package: "PlumeKit")` to the `Server` target; the
generated composition then connects via `DATABASE_URL` (runtime config) and returns
typed rows through the same `SQLDatabase`.
Build with `PKG_CONFIG_PATH=$(brew --prefix libpq)/lib/pkgconfig`. (Postgres-native
DDL, `SERIAL` vs SQLite `AUTOINCREMENT`, is handled by Migrations.)

The driver keeps a pool of asynchronous connections (default 8; set
`DATABASE_POOL_SIZE` to change it) and caches prepared statements per connection.
Behind a **transaction-mode** pooler (pgbouncer's default mode, Supabase's pooler
on port 6543) prepared statements can't be reused across backends, so set
`DATABASE_PREPARED_STATEMENTS=off` there.

### Opt-in S3

`PlumeS3` (S3 request signing via swift-crypto + URLSession; no vendor SDK) is a
separate product that works with any S3-compatible object store (S3, R2, MinIO and
others). Select it in `plumekit.toml` (`storage = "s3"`) and add
`.product(name: "PlumeS3", package: "PlumeKit")` to the `Server` target; the
generated composition reads `S3_ENDPOINT/REGION/BUCKET/ACCESS_KEY/SECRET_KEY`
(runtime config). GET/PUT/DELETE, including binary payloads, go through the same
`StorageDriver`.

### Serving stored objects

Alongside `get`/`put`/`delete`, the `Storage` handle can turn a stored object
straight into an HTTP response:

```swift
public func serve(_ key: String, contentType: String = "application/octet-stream")
    async throws -> Response
```

It streams the object's bytes with the given `Content-Type`, or returns a **404**
if the key is missing. There is no extension inference; you pass `contentType`
explicitly, so it behaves identically native and in the Wasm guest. Use it for
*runtime* user uploads (avatars, exports) that live in object storage, as opposed
to *static* files in `Public/`, which the platform serves directly (see
[Portability](portability.md#static-files-public)):

```swift
app.get("/avatars/:id") { request in
    try await Storage.current.serve("avatars/\(request.parameters["id"] ?? "")",
                                    contentType: "image/png")
}
```

### Streaming writes

`put(_:from:)` writes an object from a chunk stream — pair it with a
`body: .streaming` route (see [Routing](routing.md#streaming-bodies)) and an
upload flows into storage without ever sitting in memory whole:

```swift
app.post("/import", body: .streaming) { request in
    guard let reader = request.bodyReader else { return .status(400) }
    try await Storage.current.put("imports/latest.csv", from: reader)
    return .status(201)
}
```

The filesystem driver appends to disk (via a temp file, so a failed upload never
leaves a half-written object at the key); the S3 driver uses a multipart upload
(8 MB parts, one plain PUT for smaller objects, aborted server-side on failure).
Drivers without a streaming path collect the chunks and do one `put`.

## Capability presence is a compile-time gate

Declaring capabilities in `plumekit.toml` and *using* them are tied together at
**compile time**. A `[capabilities]` table lists what the app uses:

```toml
[capabilities]
kv       = true
database = true
storage  = true
queue    = false   # not used → no accessor generated
http     = false
```

From this the PlumeKitCodegen plugin generates a typed `Bindings` (into the App
module, shared by every target) with non-optional accessors for exactly the
declared capabilities:

```swift
public struct Bindings {
    public var kv: KV { context.kv! }            // generated: kv = true
    public var database: Database { context.database! }
    public var storage: Storage { context.storage! }
    // no `queue` / `http`; they were not declared
}
extension Request { public var bindings: Bindings { Bindings(context) } }
```

So a handler that reaches for an undeclared capability **fails to compile**.
Portability violations are build errors by design, not runtime 503s:

```
error: value of type 'Bindings' has no member 'queue'
```

(The underlying tiered protocols still hold the floor: a `Database` handle wraps
`some SQLDatabase`, so a target whose driver only meets a weaker tier can't
construct the handle; that's a compile error at the composition root. Finer tiers
such as `TransactionalStore` and `StronglyConsistentCache` follow the same handle
pattern.)
