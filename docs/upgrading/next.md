# Unreleased

<!-- unreleased-intro-start (support/prepare-release.sh drops this block at release) -->
The notes for the next release: everything below is in `main` and ships
together when the version is tagged.
<!-- unreleased-intro-end -->

This release renames the query builder entry points, makes persistence results
must-check, and rebuilds the Postgres driver around a connection pool. The
native server gains keep-alive, compression and streaming.

Every source-breaking change fails loudly at compile time. Fix what the
compiler points at, in the order below.

## Query entry points: `query()` starts a builder, `all()` executes

`Model.all()` used to return a query builder, so fetching everything read
`Post.all().all(in: db)`. The entry point is now `query()`, and `all()` always
executes:

```swift
// before
let posts = try await Post.all().order(by: Post.id).all(in: db)
let n = try await Post.all().count(in: db)

// after
let posts = try await Post.query().order(by: Post.id).all(in: db)
let n = try await Post.count(in: db)          // or Post.query()...count(in: db)
let everything = try await Post.all(in: db)   // the whole table, directly
```

`Post.where(...)` is unchanged. Old call sites fail to compile (an array has no
`.order`), so the compiler finds them all for you.

## `save()` and `upsert()` results must be read

Both return `[ValidationError]` and are no longer discardable, because ignoring
the result silently persisted nothing when a validation failed. Where the model
has no validations, discard explicitly; otherwise check:

```swift
_ = try await post.save()                       // no validations on this model
guard try await user.save().isEmpty else { … }  // handle validation failures
```

One related behaviour change: `softDelete()` and `restore()` now skip
validations, as Rails does on destroy, so a legacy row that predates a newer
rule can still be deleted.

## Removed APIs

- `Column.in(_:)` is gone. Use the generic `within(_:)`, as in
  `Post.id.within(ids)`. Same SQL, and it works for any bindable value type.
- `eagerLoad` lost its `childKey:` parameter; the child's foreign key is read
  from its schema. Better still, use the typed helper `@Model` now generates
  per has-many relation, `Post.preloadComments(posts)`, and the stringly-typed
  seam disappears from your code entirely. A misspelled foreign-key name now
  surfaces natively as a thrown error (one 500) rather than a malformed-SQL
  error.
- The `PostgresDatabase` class is gone. Construct through
  `PostgresDriver.connect(url:poolSize:preparedStatements:)`, which returns the
  pooled `Database`. Generated composition roots already do.
- `StaticFiles.response(for:in:)` in the native server was replaced by a
  stat-plus-stream design (`resolveRoot` and `lookup`). Only relevant if you
  called it directly.
- `RouteMatch.found` carries a third associated value, the route's request body
  mode. Only relevant if you match on `Router` results yourself.

## Migrations now run in transactions

Each migration and its ledger row commit together on the native drivers, so a
failed script no longer leaves half-applied DDL behind. If a migration uses a
statement Postgres refuses inside a transaction block, such as `CREATE INDEX
CONCURRENTLY` or `VACUUM`, mark it out:

```swift
let addIndex = Migration.sql(
    version: "20260801_concurrent_index",
    transactional: false,
    up: "CREATE INDEX CONCURRENTLY idx_posts_slug ON posts (slug);"
)
```

D1 migrations are unchanged: forward-only SQL batches, no transactions there.

## The Postgres driver is a pool now

Native Postgres runs on a pool of asynchronous connections instead of one
locked connection, so a long transaction no longer blocks every other request.
The defaults are sensible, and two environment switches exist:

- `DATABASE_POOL_SIZE` sets the pool size (default 8).
- `DATABASE_PREPARED_STATEMENTS=off` is required behind a transaction-mode
  pooler (pgbouncer's default mode, Supabase's pooler on port 6543), where
  server-side prepared statements can't be reused across backends. Session-mode
  poolers and direct connections need nothing.

## Native server behaviour changes

Usually no action needed, but worth knowing:

- HTTP/1.1 keep-alive is on for apps without realtime channels. Apps with
  channels keep closing per request: a WebSocket upgrade can only happen on a
  connection's first request, and some clients reuse pooled connections for the
  handshake.
- Responses and static files are gzipped automatically for clients that accept
  it (text-ish content types only), and static files carry `ETag` and
  `Last-Modified` validators with 304 handling. A handler that sets its own
  `Content-Encoding` is passed through untouched.
- A request body that stalls for 60 seconds between chunks closes the
  connection. Tune with `PlumeServer.requestBodyIdleTimeoutMillis`.
- Default 405s from unimplemented controller actions now respect
  `app.errorPage(405)`.

## One-time edits to files your app owns

The new `plumekit migrate --rollback [N]` and `--status` commands drive the
Server binary with `--rollback` and `--migration-status` flags. Apps scaffolded
before this release don't parse them; the CLI detects that and refuses, rather
than accidentally booting your server. Copy the two argument cases and their
handling blocks from a freshly scaffolded app's Server main into your
`Sources/Server/main.swift`.

Enabling `database` or `storage` after scaffolding requires the matching driver
product (`PlumePostgres` or `PlumeS3`) in the Lambda target of `Package.swift`.
The generators patch this for you when they flip a capability; a manual flip
that misses it fails with a `#error` naming the exact line to add.

## New since the last release, no action needed

Worth adopting: streaming response bodies and streaming upload routes with
storage sinks ([Routing](../routing.md#streaming-bodies),
[Bindings](../bindings.md#streaming-writes)), bulk `delete()` and `updateAll`
with aggregates on the query builder, `paginate(request)`, typed relation
preloads, `identityMiddleware()` wired from bindings in one line,
`app.postForm` in tests with automatic CSRF, `plumekit migrate --status` and
`--rollback`, browser live-reload under `plumekit dev`, and generators that
offer to enable missing capabilities.
