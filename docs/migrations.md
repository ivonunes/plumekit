# Migrations

Versioned schema changes. Each migration is a file that describes one change with an
explicit `up` (and an optional `down` to reverse it). Migrations run in order, once
each, and are discovered automatically, so you never maintain a central list.

They talk only to the neutral `Database`, so the same migrations run on native SQLite,
Cloudflare D1 and Postgres; the dialect travels with the handle.

## Writing a migration

Create one with the generator:

```sh
plumekit generate migration CreatePosts
#   + Sources/App/Database/Migrations/20260101120000_CreatePosts.swift
```

The filename is timestamped so migrations order by creation time and two branches
never collide on the same number. Fill in the change with the schema builder:

```swift
import PlumeORM

let createPosts = Migration(
    version: "20260101120000_create_posts",
    up: { db in
        try await db.createTable("posts") { t in
            t.id()
            t.text("title")
            t.integer("views")
            t.boolean("published")
            t.references("author", table: "users")   // author_id + foreign key
            t.timestamps()                            // created_at / updated_at
        }
        try await db.addIndex(on: "posts", columns: ["published"])
    },
    down: { db in try await db.dropTable("posts") }
)
```

Columns are `text`, `integer`, `real`, `boolean`, `uuid`, `blob` and `id()` for the
primary key; each takes `nullable: true` for an optional column. Non-nullable columns
get `NOT NULL`. Spelling the schema out keeps the migration a **frozen record**: it
does not read the live `@Model`, so editing a model later never rewrites past
migrations.

## Altering a table

```swift
let addSlug = Migration(
    version: "20260102090000_add_slug_to_posts",
    up: { db in
        try await db.alterTable("posts") { t in
            t.addColumn("slug", .text, nullable: true)
            t.renameColumn("title", to: "headline")
            t.dropColumn("legacy_flag")
        }
        try await db.addIndex(on: "posts", columns: ["slug"], unique: true)
    },
    down: { db in
        try await db.alterTable("posts") { t in t.dropColumn("slug") }
    }
)
```

`renameTable`, `dropIndex` and `addReference` round out the set. Renaming and dropping
columns need SQLite 3.25+/3.35+; Cloudflare D1 and recent SQLite have both.

## Raw SQL

For anything the builder doesn't cover, run SQL directly in the closure:

```swift
up: { db in _ = try await db.query("CREATE TABLE ... CHECK (...)", []) }
```

Or write the whole migration as SQL with `Migration.sql`, which splits `up`/`down`
into `;`-terminated statements:

```swift
let m = Migration.sql(
    version: "20260103_add_view",
    up: "CREATE VIEW recent_posts AS SELECT * FROM posts ORDER BY created_at DESC;",
    down: "DROP VIEW recent_posts;"
)
```

## Running migrations

`plumekit migrate` applies every pending migration against the configured database.
For Cloudflare D1, choose where they run:

```sh
plumekit migrate            # native database (SQLite/Postgres, per plumekit.toml)
plumekit migrate --local    # the local D1 (wrangler's local SQLite)
plumekit migrate --remote   # the deployed D1
```

The `Migrator` records what has run in a `schema_migrations` ledger (`version`,
`applied_at`), so re-running is a no-op. `plumekit deploy` runs migrations for you as
part of a deploy, controlled by the `[deploy]` section of `plumekit.toml`.

### Rollback and status

Both are CLI commands against the native database:

```sh
plumekit migrate --status        # each migration:  up/down
plumekit migrate --rollback      # reverse the most recent (its down:)
plumekit migrate --rollback 3    # reverse the last three
```

The same operations exist as Swift APIs on the `Migrator` (the set is
`plumeKitMigrations`, the generated list of your migration files):

```swift
let migrator = Migrator(plumeKitMigrations)
try await migrator.rollback(in: db, steps: 1)   // reverse the most recent, running its down
let states = try await migrator.status(in: db)  // each migration and whether it's applied
```

A migration with no `down` throws `MigrationError.irreversible`. Each migration
and its ledger row are applied (and rolled back) in one transaction on the native
drivers, so a failed script leaves nothing half-applied. D1 is forward-only: to
undo something there, write a new migration.

Statements Postgres refuses inside a transaction block (`CREATE INDEX
CONCURRENTLY`, `VACUUM`) go in a migration marked `transactional: false`
(`Migration(version:transactional:up:down:)` or
`Migration.sql(version:transactional:up:down:)`). Keep those to one statement:
without the wrapper, a mid-script failure leaves whatever ran behind.

### Adopting an existing database

To introduce migrations onto a database that already has the tables, pass
`adoptExistingTable:`. When the ledger is empty but that table already exists, every
migration is recorded as applied *without running*, so a live schema is never
re-created:

```swift
try await migrator.migrate(in: db, adoptExistingTable: "posts")
```

## Seeders

Seeders are files under `Sources/App/Database/Seeders/`, also discovered
automatically. A `Seeder` inserts rows; make it idempotent (upsert) if it may run more
than once:

```sh
plumekit generate seeder Posts
#   + Sources/App/Database/Seeders/PostsSeeder.swift
```

```swift
import PlumeORM

let postsSeeder = Seeder { _ in
    _ = try await Post(title: "Welcome", views: 0, published: true).upsert()
}
```

Run them:

```sh
plumekit seed          # run every seeder
plumekit seed posts    # run just PostsSeeder
```

`plumekit seed` also takes `--local` / `--remote` for Cloudflare D1.

## Dialects

The same migrations run on every SQL target. The builder renders dialect-correct DDL
from the handle (e.g. `INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite/D1 versus
`SERIAL PRIMARY KEY` on Postgres), so a migration stays identical across targets. If
you hand-write SQL that differs between engines, that's the one place to mind the
dialect. See [Portability](portability.md).
