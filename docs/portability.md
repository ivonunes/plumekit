# Portability

PlumeKit is one portable core with per-target adapters: the same `buildApp()` runs
natively (a long-lived SwiftNIO process), as a tiny Wasm module inside a Cloudflare
Worker, and as a `provided.al2` custom runtime on AWS Lambda. Switching targets is a
**manifest swap**: you change `plumekit.toml` (and, for Cloudflare, `wrangler.toml`)
and rebuild. No app code changes, and no `if platform == …` branches. This page
covers how that invariant is kept. For the manifest and CLI, see [The CLI &
config reference](cli.md); for building and shipping each target, see
[Deploying](deploying.md). For the AWS runtime specifically, see [Deploying to AWS
Lambda](aws.md).

## One core, many adapters

Every host capability (SQL, KV, object storage, cache, queues, secrets, HTTP, mail,
channels) is a neutral protocol with a concrete handle. Each target
supplies its own adapters:

- **Native**: SQLite or Postgres, filesystem object storage, an in-memory cache, an
  in-process queue, environment secrets and a long-lived actor for channels.
- **Cloudflare**: D1, R2, Workers KV (durable, and again as a cache), Queues, `env`
  secrets and a Durable Object per channel.
- **AWS**: RDS Postgres, S3, DynamoDB (durable KV, and again as a TTL cache), SQS,
  SSM Parameter Store secrets, SES mail and API Gateway WebSockets per channel. Wired
  from the `[targets.aws]` profile as `Composition.awsContext()`, exactly like the native
  composition. See [Deploying to AWS Lambda](aws.md).

The manifest selects which adapters are linked; the generated composition root wires
them into the `Context` handlers receive. App code names a capability
(`request.bindings.database`), never a platform type.

## Keeping SQL portable

The subtle portability work is SQL. Native SQLite and Cloudflare D1 both speak the
**SQLite dialect**, where `INTEGER` is dynamically 64-bit and identifiers keep their
case. Postgres (a native driver) breaks both assumptions. Each difference is fixed
once, at the protocol or ORM layer, never in app code:

| Difference | Fix (at the protocol / ORM layer) |
|---|---|
| Dialect-specific DDL (`AUTOINCREMENT` vs `SERIAL`) | The dialect travels with the `Database` handle (set by the adapter). `createTable` and migrations render columns through the handle's dialect, so app code names no dialect. |
| Schema introspection differs (`PRAGMA table_info` vs `information_schema`) | `introspectColumns` is dialect-aware. |
| Epoch-millis timestamps overflow 32-bit `INTEGER` on Postgres | The `schema_migrations` ledger's `applied_at` is `BIGINT` on Postgres, `INTEGER` on SQLite/D1 (already 64-bit there). |
| `lastInsertID` is 0 on Postgres | `save()` uses `INSERT … RETURNING id` on Postgres to get the database-generated id; UUID/string keys are supplied by app code. |
| Postgres folds identifiers to lowercase | Column matching is case-insensitive (`asciiEqualFold`); SQL identifiers are case-insensitive anyway. |

Because the dialect is carried by the adapter and selected by the manifest
(`database = "postgres"`), the same `@Model`, query builder and migrations run
unchanged on SQLite, D1 and Postgres.

## Real-time channels are portable too

Channels are the hardest thing to keep portable, because the runtimes are
structurally different: a Cloudflare Durable Object holds per-channel state and
can't `await` a store mid-handler, while the native runtime is a long-lived actor.
The `Channel` protocol is shaped for the stricter of the two (a synchronous handler
over a pre-loaded store whose effects, i.e. writes, deferred SQL and pushes, the
adapter applies), so the same `Channel` code drives both. That same shape drives a
**third** runtime unchanged: on AWS the connection and per-channel state live in
DynamoDB and the adapter fans out with API Gateway's `postToConnection`, with no
change to the `Channel` code. Payload-agnostic delivery and signed subscriptions
work through the protocol unchanged. See [Channels](channels.md).

## Static files (`Public/`)

Scaffolded apps have a `Public/` directory. Your app references an asset by the
**same URL path on every target** (`/app.<hash>.css`, `/logo.png`); only
*who* serves it changes:

- **Native** (`plumekit serve`): the server serves any file under `Public/` at its
  URL path (`Public/images/logo.png` →
  `/images/logo.png`). It is path-traversal-safe, sets `Content-Type` by file
  extension, sends `Cache-Control` plus `ETag`/`Last-Modified` validators (repeat
  visits get 304s), streams large files in chunks, and gzips text-ish content for
  clients that accept it — HTML, CSS, JS and JSON responses from your routes are
  compressed the same way. Static files take priority for GET; a miss falls
  through to your routes.
- **Cloudflare**: `plumekit build --target cloudflare` copies `Public/` →
  `dist/cloudflare/public`, and the generated `wrangler.toml` gets an `[assets]`
  block (`directory = "./public"`). Cloudflare serves a matching path directly;
  every other request runs the Worker.
- **AWS**: `plumekit build --target aws` copies `Public/` → `dist/aws/public`. You
  upload it to S3 and front it with CloudFront, which routes dynamic paths to the
  Lambda. See the generated `dist/aws/README.md` for the exact `aws s3 sync` command
  and CloudFront setup.

In templates, `asset("name")` resolves to these URLs (content-hashed for the Plume
bundle, pass-through for your own files); see [Resources](customise/resources.md#assets).
`Public/app.*` is the regenerated bundle and is gitignored; your own files under
`Public/` are tracked. For *runtime* uploads (as opposed to static files), stream
them from object storage with [`Storage.serve`](bindings.md#serving-stored-objects).

## Capability tiers

The binding design distinguishes the portable floor (`Database`) from the SQL
refinement (`SQLDatabase`). Code that uses the query builder or `@Model` requires the
refinement, so a target that vended only the floor would fail to **compile** for that
code: portability enforced as a build error, not discovered at runtime.

## The Wasm constraints, in practice

Your handlers, models and views compile to Embedded-Swift Wasm for the Cloudflare
target, which brings a few concrete rules for your own code:

- **No Foundation, no runtime reflection.** PlumeKit's JSON, row codec and form
  parsing are all explicit for this reason; your code should not reach for
  `Codable`/`JSONEncoder`.
- **Native `String` operations now work.** `String ==` / `!=`, `hasPrefix` /
  `hasSuffix`, `lowercased()` / `uppercased()`, `Dictionary<String, _>`, and
  `Character`/grapheme iteration all link and run in the guest with **full,
  native-identical Unicode semantics** (canonical equivalence, real case mapping,
  not byte approximations). This works because `plumekit build --target cloudflare`
  links Swift's Unicode data tables (`libswiftUnicodeDataTables.a`) into the Wasm
  build automatically, with no app opt-in. The tables are pulled in only when your code
  actually uses these operations, and only the referenced slices, so the cost is
  small (≈40 KB compressed for `==`; the whole table set is ~0.75 MB uncompressed,
  well inside the Workers size limits). `String.split(separator:)` works too. Framework
  internals still compare bytes (`Plume.equal`, `utf8Equal`) so an app that never uses
  these operations stays minimal. Reach for the byte helpers only when you want to
  avoid pulling the tables in a size-critical path.
- **`import _Concurrency`** is required in any file using async.
- **32-bit `Int`.** Use `Int64` for values that may exceed 2^31 (e.g. epoch
  milliseconds; `@Model` enforces `Int64` timestamps).

These only bite in code you write yourself; every framework API is already safe on
all targets.
