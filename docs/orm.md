# The ORM

Code-first models with a compile-time macro instead of runtime
metaprogramming. Embedded Swift has no runtime reflection, so `@Model` reads the
type at **compile time** and emits, as plain static code, everything
ActiveRecord would generate at runtime. The ORM talks only to the
`Database`/`SQLDatabase` protocols, so the **same model runs on D1 and native
SQLite**.

> ORM calls use the current database automatically, so you write `post.save()`, not
> `.save(in: db)`. Every method also takes an optional `in db:` for a test, which has
> no ambient database.

## What `@Model` generates

```swift
@Model
final class Post: Model {
    var id: Int            // `id` = primary key by convention
    var title: String
    var views = 0
    var published = false
}
```

- `static let schema: TableSchema`: table (pluralised `snake_case`), columns
  (`snake_case` by default, overrideable with `@Column`), types, PK.
- A row codec: `init(row:)` decodes by *index* (`row.string(1)`),
  never by column name, because name matching needs Unicode-aware `String ==`,
  which doesn't link in the Wasm build. The query builder always projects columns
  in schema order, so positions line up.
- `columnValues()`: values in schema order.
- A memberwise `init` (non-PK fields), and **dirty tracking** (an original-value
  snapshot, so `save` writes only the changed columns).
- Typed query columns: `static let title = Column<Post, String>("title")`.

## Persistence (active record)

```swift
let post = Post(title: "Hi", views: 5, published: false)
let errors = try await post.save()   // INSERT; populates post.id from lastInsertID
guard errors.isEmpty else { … }      // validation failures come back as values
post.published = true
_ = try await post.save()            // UPDATE: only the changed columns (dirty tracking)
_ = try await post.upsert()          // INSERT, or UPDATE if the primary key already exists
try await post.delete()
let one = try await Post.find(42)    // Post?
```

`save()` (and `upsert()`) validates first and **returns** the validation errors,
persisting nothing when any rule fails; real database errors still throw. The
result is deliberately not discardable: write `_ =` when the model has no
validations, check the array when it does. See
[Validations](validations.md).

`save`/`delete`/`find` are written **once**, generically over `Model` + the
`Database` protocol. All SQL is built by ASCII append; values are always
bound `?` parameters, never interpolated. A minimal `createTable(in:)`
(create-if-not-exists from the schema) exists for tests and local dev; it is
**not** the migration system (see [Migrations](migrations.md)).

Integer `var id: Int` remains the default database-generated primary key. UUID
primary keys are first-class as app-generated keys:

```swift
@Model
final class AccessToken: Model {
    var id: UUID          // PlumeORM.UUID, stored as TEXT/UUID by dialect
    var label: String
}

let token = AccessToken(label: "primary")   // id defaults to UUID()
_ = try await token.save(in: db)            // INSERT includes the UUID key
let found = try await AccessToken.find(token.id, in: db)
```

Inside a handler, `find` also binds straight from the route (**route model
binding**): the read-`:id`-parse-find preamble becomes one guard:

```swift
guard let post = try await Post.find(request) else { return .status(404) }
```

It reads `request.parameters["id"]` and parses the integer key; pass
`parameter: "post_id"` for nested routes. Like every lookup, it respects the
model's default scope, so a soft-deleted row is not found.

## Typed query builder

`Post.query()` starts a builder; `Post.where(...)` starts it filtered. The
executing terminals are `all()`, `first()`, `count()`, `exists()` and friends,
so which call hits the database is always visible. `Post.all()` /
`Post.count()` run directly for the everyday whole-table cases.

```swift
let everything = try await Post.all()
let recent = try await Post
    .where(Post.published == true && Post.views > 100)
    .order(by: Post.views, .descending)
    .limit(10)
    .all()
let n = try await Post.where(Post.published == false).count()
let latest = try await Post.query().order(by: Post.id, .descending).first()   // Post?
let page3 = try await Post.query().order(by: Post.id).offset(40).limit(20).all()

// Chained `order` calls compose into a multi-column ORDER BY.
let ranked = try await Post.query().order(by: Post.published).order(by: Post.views, .descending).all()

// Cheap probes and projections — no row decoding:
let any = try await Post.where(Post.published == true).exists()        // SELECT 1 … LIMIT 1
let ids = try await Post.where(Post.published == true).pluckInts(Post.id)
let hits = try await Post.where(Post.id.within(ids)).all()             // typed IN (…)

// Aggregates run in SQL:
let views = try await Post.query().sum(Post.views)
let top = try await Post.query().maximum(Post.views)                   // Int? (nil with no rows)

// Bulk writes: one statement, no per-row loads (callbacks don't run):
try await Post.where(Post.published == false).updateAll(Post.views.set(0))
try await Post.where(Post.views == 0).delete()

// Pagination: order by a stable column for deterministic pages. The Page gives
// views everything they need: page.items, page.page, page.previousPage/nextPage,
// page.previousURL("/posts")/nextURL("/posts"), and (with `withTotal: true`, one
// extra COUNT) page.total/totalPages. Return it with `.json(page)` for the
// standard paginated envelope.
let page = try await Post.query().order(by: Post.id).paginate(page: 2, per: 20, withTotal: true)

// Or straight from the request: reads the `page`/`per` query params (the same
// names Page.url emits), clamping `per` to `maxPer`.
let fromRequest = try await Post.query().order(by: Post.id).paginate(request)
```

`Column<Root, Value>` and `Predicate<Root>` are **concrete generic value types**.
Operators only type-check against matching value types, so a
wrong-type predicate is a **compile error**:

```swift
Post.published > 100   // error: binary operator '>' cannot be applied to
                       //        'Column<Post, Bool>' and 'Int'
```

Predicates lower to
parameterised SQL; text collation/ordering is delegated to the database (the guest
has no Unicode tables).

## Relationships

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    @HasMany var comments: [Comment]   // → Comment.post_id
}
@Model final class Comment: Model {
    var id: Int
    var body: String
    @BelongsTo var post: Post?         // → a `post_id` column
}

let comments = try await post.$comments.load(in: db)   // explicit, one query
let parent   = try await comment.$post.load(in: db)
```

`@BelongsTo`/`@HasMany` are property wrappers giving `$post` / `$comments` handles.
Loading is **explicit and async**: no property access silently fires a query.
`@Model` reads the wrapper attributes and generates the FK column (`post_id`) for
belongs-to and injects the owner id into has-many handles via `refreshRelations()`.

> Relations work with **any primary-key type**. The foreign key stores the parent's
> raw key, so a `@BelongsTo`/`@HasMany` on a UUID- or String-PK model resolves
> correctly (the child's FK column mirrors the parent key's type). Read `$post.id` for
> the integer FK in the common case, or `$post.key` for the raw `SQLValue` of any key
> type.

An **unloaded** relation reads as empty (`post.comments` is `[]`, `comment.post`
is nil) — it never auto-loads. When "not loaded" and "none" must be told apart,
check `$comments.isLoaded` / `$post.isLoaded`, or just load first.

Eager loading is **batched** (no N+1): for many owners it issues **one** child
query, then groups and assigns. `@Model` generates a typed helper per has-many,
so a page preloads an association in one line:

```swift
let posts = try await Post.all()
try await Post.preloadComments(posts)      // ONE query fills every post's $comments
```

The underlying seam is `eagerLoad(_:foreignKey:assign:in:)` for hand-written
stores; the generated helper supplies the FK name and the assignment, so a typo
can't reach it.

Keypaths don't compile under embedded Wasm, which shapes two corners of this API:
- Eager loading uses a closure assignment, not `.with(\.$comments)` keypaths (and
  the enclosing-self wrapper subscript, which needs `ReferenceWritableKeyPath`, is
  out, hence `refreshRelations()`).
- `@BelongsTo var author: User?` is optional (nil until loaded), not `User`.

## Auto-managed timestamps

A model opts in by declaring `createdAt`/`updatedAt` as **`Int64`** (epoch millis
would overflow the 32-bit `Int` on wasm, so `@Model` rejects a non-`Int64` field):

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    var createdAt: Int64 = 0   // set on INSERT
    var updatedAt: Int64 = 0   // set on every save
}
```

`save()` sets them from `ORMClock`, a wall-clock seam installed per platform
(Foundation `Date` natively via `PlumeServer`; a `host_now` → JS `Date.now()`
import on Workers).

## Transactions

`db.transaction { tx in … }` runs its body atomically: the writes commit together,
a thrown error rolls every one of them back (then rethrows), and the body's return
value becomes the call's value:

```swift
let order = try await db.transaction { tx in
    _ = try await order.save(in: tx)
    _ = try await tx.query("UPDATE inventory SET held = held + 1 WHERE sku = ?", [sku])
    return order
}
```

Queries on `tx`, **and ambient ORM calls made inside the body**, join the
transaction (it's task-local), while other requests' queries wait on a connection
lock, so no statement from another request can slip inside an open transaction. A
nested `transaction` joins the outer one. Available on native SQLite and Postgres.
**Cloudflare D1 has no interactive transactions** (each statement is atomic on its
own), so calling `transaction` there is a programming error that traps with a clear
message.

## Soft deletes

Conform a model to `SoftDeletable` and declare a `deletedAt` column (epoch seconds;
`0` = live):

```swift
@Model
final class Post: Model, SoftDeletable {
    var id: Int
    var title: String
    var deletedAt = 0        // epoch seconds; 0 = live
}
```

Every query, and `find`, hides trashed rows automatically:

```swift
try await post.softDelete()          // hide: stamps deletedAt, keeps the row
try await post.restore()             // bring it back
try await post.forceDelete()         // actually DELETE the row

try await Post.withTrashed().all()   // everything
try await Post.onlyTrashed().all()   // just the hidden ones
```

Any query opts out per call with `.unscoped()`.

## Query scopes

A model can pre-filter **every** query with a default scope; soft deletes are
implemented on exactly this hook:

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    var published = false

    static var defaultScope: Predicate<Post>? { Post.published == true }
}
```

Every `where`/`all`/`count`, and `find`, starts from the scope; `.unscoped()` on
any query bypasses it.

## Lifecycle callbacks

Override the persistence hooks on the model. All are `async throws`, no-ops by
default:

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    var slug = ""

    func willSave() async throws {       // after validation, before the write
        slug = slugify(title)            // your own helper; mutate fields here.
    }                                    // throwing aborts the save
}
```

`willSave` runs after validation and before the write: the place to derive fields
like a slug; throwing aborts the save. `willDelete` runs before a delete and
throwing aborts it; `didSave` / `didDelete` run after the row is written / removed.

## How the ambient database works (and when `in: db` is required)

Inside a handler, ORM calls take the current request's database implicitly: the
framework binds the request's context around dispatch. On native builds that binding
is **task-local** (`RequestContext.withValue`), so several apps dispatching in one
process (e.g. parallel test suites, each with its own `TestApp`) never see each
other's database. Long-lived non-request code (server startup, migrations, the
console, schedule ticks) assigns `RequestContext.current = context` instead; that
writes a process-global fallback which reads fall back to when no task-local binding
is in scope. (The embedded-wasm guest keeps a plain global for both because
`@TaskLocal.withValue` doesn't compile under embedded wasm: safe there, since the
guest handles one request per instance. A transaction, which needs per-task routing
even within one app, uses a task-local that only exists in the native build; see
[Transactions](#transactions).)

Migrations, seeders, background jobs and the console get the same ambient binding
(the runner binds the context before dispatch), so `in: db` there is optional too.
Tests are the one place with no ambient database, which is why test code passes
the handle explicitly: `post.save(in: app.database)`.
