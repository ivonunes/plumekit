# Generators

`plumekit generate <kind>` (alias `g`) scaffolds common pieces of an app. Generators
**never overwrite** an existing file, and each one prints how to wire what it created
(a route to register, a middleware to `use`, …). Migrations and seeders are picked up
automatically. Run them from the project root.

| Command | Creates |
| --- | --- |
| `generate resource <Name> [field:type …]` | A full CRUD resource: model, controller (all seven actions), index/new/show/edit views, and a migration file (auto-discovered); prints the route to register. |
| `generate auth` | Email + password auth: User model, register/login/logout/forgot/reset plus email verification; works for browser sessions **and** JSON APIs. |
| `generate notifications` | Two-channel notifications: a `UserNotification` model (the in-app inbox) plus a `notify(...)` helper that also emails when the mailer is bound. |
| `generate model <Name> [field:type …]` | An `@Model` type plus its migration file. |
| `generate controller <Name>` | A RESTful `Controller` (the seven actions: index/new/create/show/edit/update/destroy). |
| `generate migration <Name>` | A timestamped migration file (schema builder) under `Database/Migrations/`. |
| `generate view <Name>` | A standalone Plume component (`Views/<Name>.plume`). |
| `generate middleware <Name>` | A `Middleware` struct. |
| `generate job <Name>` | A background `Job` under `Sources/App/Jobs/` — auto-registered on the next build (no manual wiring). |
| `generate seeder <Name>` | A `Seeder` (in `Database/Seeders/`). |
| `generate test <Name>` | A test suite in `Tests/AppTests/`. See [Testing](testing.md). |
| `generate ci --provider <github\|gitlab\|forgejo>` | CI workflows (test on PR, deploy on push). See [Deploying](deploying.md). |

## Field types

`field:type` pairs accept `string` (the default), `text`, `int`, `int64`, `double`,
`bool`, and `blob`. They map to the Swift property type and, in generated migrations,
the SQL column type (`TEXT` / `INTEGER` / `REAL` / `BLOB`). Table and column names
match what `@Model` derives (pluralized, snake_cased).

## resource

The full-resource scaffold: everything for a resource, as a working starting
point:

```sh
plumekit generate resource Post title:string body:text published:bool
```

It creates:

- `Sources/App/Models/Post.swift`: the `@Model`.
- `Sources/App/Controllers/PostController.swift`: a `Controller` with working CRUD;
  `index` lists, `new`/`edit` render the create/edit forms, `show` finds by id,
  `create`/`update` read the form and save, `destroy` deletes.
- `Views/Post/{Index,New,Show,Edit}.plume`: a list (with a "New" link), a create form,
  a detail view (with Edit/Delete), and a pre-filled edit form (method-overridden to
  PATCH), using your shared `Layout`. The New and Edit forms repopulate submitted values
  and show per-field messages when a save fails validation (the controller re-renders
  New/Edit at 422 with `old*`/`*Error` filled). Each resource's views are grouped in their
  own `Views/<Name>/` folder (PascalCase, like the rest of the tree) so the directory stays
  tidy as the app grows.
  (The `@component` names stay globally unique (`PostIndex`, `PostNew`, `PostShow`,
  `PostEdit`) because they compile to top-level render functions; the folder just organizes
  files.)
- A model factory and a test suite (see [Testing](testing.md)).

The scaffold wires in the conveniences you'd otherwise add by hand:

- **Named routes**: a `PostRoutes` enum declares each path once; the controller
  registers with it and builds its redirect URLs from it
  (`PostRoutes.show.path(item.id)`). See [Routing](routing.md#named-routes).
- **Validation with re-render**: `create` validates the input (`.required` on
  every field, plus `.integer`/`.decimal` for numeric ones); on failure it
  re-renders the index with status 422, the submitted values repopulated
  (`value="{oldTitle}"`), and an inline `<span class="field-error">` message per
  field via `input.errors.first("title")`. See [Forms](forms.md).
- **Flash messages**: create/update/destroy redirect with
  `.flash("Post created")` (and "updated" / "deleted"), and the Index view renders
  the `.flash` banner. See [Routing](routing.md#flash-messages).

and writes the migration file, then prints the route to register:

```swift
app.resources("posts", PostController())
```

Requires the `database` capability. Run `plumekit migrate` and the migration is picked
up automatically.

## auth

A complete email + password auth scaffold that works for **both browser sessions** (a
signed, HTTP-only cookie) **and API clients** (a bearer token). Identity resolves the
same way for both, so every route serves both kinds of client:

```sh
plumekit generate auth
```

It creates the `User`, `PasswordReset`, and `EmailVerification` models (in
`Sources/App/Models/`; the `users` table is the source of truth),
`Sources/App/Controllers/Auth.swift` (the authenticator, session manager, and an
`AuthController` with **register / login / logout / forgot-password / reset /
verify**), the four page views in `Views/Auth/`, and the two email bodies in
`Views/Emails/` (verification + password reset; emails are their own kind of view,
so they get their own folder). It prints the migrations and the wiring steps:

1. Enable the `kv` and `database` capabilities in `plumekit.toml`.
2. Call `installAuth(app)` in `buildApp()`; it registers the identity middleware and
   the routes (`/register`, `/login`, `/logout`, `/forgot`, `/reset`, plus
   `GET /verify` and `POST /verify/resend`).
3. Set `AUTH_SECRET` (`wrangler secret put AUTH_SECRET`, or your env) before deploying.
4. Run `plumekit migrate` (the migration file is auto-discovered).

In any handler, `request.currentUser` is the signed-in user id and
`request.isAuthenticated` the flag. A browser gets a session cookie and a redirect; a
client sending `Accept: application/json` gets `{"token": "…"}` and passes it back as
`Authorization: Bearer …`. Forgot-password stores a one-time token and emails the reset
link as a Plume-view email (`Views/Emails/ResetEmail.plume`) when the
[mailer](mailer.md#plume-view-email-bodies) is bound; in local dev, with no mailer,
the link is logged instead. The scaffold builds on
the primitives in [Auth](auth.md), which you can drop down to for OAuth, policies, etc.

**Email verification** is scaffolded in: registration creates an `EmailVerification`
token and emails the link as a **Plume-view email** (`Views/Emails/VerifyEmail.plume`,
rendered through the scaffold's `Mailer.send(view:text:)` helper,
see [Mailer](mailer.md#plume-view-email-bodies)); without a mailer binding the link is
logged, so dev keeps working. `GET /verify?token=…` stamps `User.verifiedAt`
(one-time, 24 h expiry, flash confirmation) and `POST /verify/resend` re-sends. Gate
verified-only routes with:

```swift
if let blocked = try await requireVerified(request) { return blocked }
```

The `users` migration includes `verified_at INTEGER NOT NULL DEFAULT 0`.

## notifications

Two-channel notifications: an in-app inbox plus email when the
mailer is bound:

```sh
plumekit generate notifications
```

It creates a `UserNotification` `@Model` (the inbox) and a
`notify(userID:email:title:body:)` helper that writes the inbox row and also emails
when the [mailer](mailer.md) capability is bound. Read a user's inbox with
`UserNotification.for(userID)` and mark entries read with `markRead()`. The migration
file is written for you and picked up on the next `plumekit migrate`.

## model & migration

```sh
plumekit generate model Post title:string views:int published:bool
```

Writes the `@Model` and a migration file that creates its table. `generate migration
<Name>` writes a blank migration file for a schema change not tied to a new model. Both
land under `Database/Migrations/` and run automatically. See [Migrations](migrations.md).

## controller, view, middleware, job, seeder

Each writes one file and prints how to wire it:

```sh
plumekit generate controller Post       # → app.resources("posts", PostController())
plumekit generate view Sidebar          # → Views/Sidebar.plume
plumekit generate middleware RateLimit  # → app.use(RateLimitMiddleware())
plumekit generate job SendEmail         # → registry.register(SendEmailJob.self) in buildJobs()
plumekit generate seeder Demo           # → Database/Seeders/DemoSeeder.swift; run with `plumekit seed`
```

See [Controllers](controllers.md), [Plume views](plume-views.md),
[Middleware](middleware.md), [Jobs](jobs.md), and the [CLI reference](cli.md).
