# Generators

`plumekit generate <kind>` (alias `g`) scaffolds the common pieces of an app: a model, a controller, a whole CRUD resource, auth and more. Generators **never overwrite** an existing file, and each one prints how to wire what it created (a route to register, a middleware to `use`). Migrations and seeders are picked up automatically. Run them from the project root.

| Command | Creates |
| --- | --- |
| `generate resource <Name> [field:type …]` | A full CRUD resource: model, controller (all seven actions), index/new/show/edit views and a migration file (auto-discovered); prints the route to register. |
| `generate auth` | Email + password auth: User model, register/login/logout/forgot/reset plus email verification; works for browser sessions **and** JSON APIs. |
| `generate notifications` | Two-channel notifications: a `UserNotification` model (the in-app inbox) plus a `notify(...)` helper that also emails when the mailer is bound. |
| `generate model <Name> [field:type …]` | An `@Model` type plus its migration file. |
| `generate controller <Name>` | A RESTful `Controller` (the seven actions: index/new/create/show/edit/update/destroy). |
| `generate migration <Name>` | A timestamped migration file (schema builder) under `Database/Migrations/`. |
| `generate view <Name>` | A standalone Plume component (`Views/<Name>.plume`). |
| `generate middleware <Name>` | A `Middleware` struct. |
| `generate job <Name>` | A background `Job` under `Sources/App/Jobs/`, auto-registered on the next build (no manual wiring). |
| `generate seeder <Name>` | A `Seeder` (in `Database/Seeders/`). |
| `generate test <Name>` | A test suite in `Tests/AppTests/`. See [Testing](testing.md). |
| `generate ci --provider <github\|gitlab\|forgejo>` | CI workflows (test on PR, deploy on push). See [Deploying](deploying.md). |

## Field types

`field:type` pairs accept `string` (the default), `text`, `int`, `int64`, `double`, `bool` and `blob`. Each maps to a Swift property type and, in generated migrations, a SQL column type (`TEXT`, `INTEGER`, `REAL` or `BLOB`). Table and column names match what `@Model` derives: pluralised and snake_cased.

## resource

When you start a new feature, you usually want the whole vertical slice at once. The `resource` generator scaffolds everything for one resource as a working starting point:

```sh
plumekit generate resource Post title:string body:text published:bool
```

It creates:

- `Sources/App/Models/Post.swift`: the `@Model`.
- `Sources/App/Controllers/PostController.swift`: a `Controller` with working CRUD. `index` lists, `new` and `edit` render the forms, `show` finds by id, `create` and `update` read the form and save, `destroy` deletes.
- `Views/Post/{Index,New,Show,Edit}.plume`: a list (with a "New" link), a create form, a detail view (with Edit/Delete) and a pre-filled edit form (method-overridden to PATCH), all using your shared `Layout`.
- A model factory and a test suite (see [Testing](testing.md)).

Each resource's views live in their own `Views/<Name>/` folder (PascalCase, like the rest of the tree), so the directory stays tidy as the app grows. The `@component` names stay globally unique (`PostIndex`, `PostNew`, `PostShow`, `PostEdit`) because they compile to top-level render functions; the folder just organises files.

The scaffold also wires in the conveniences you would otherwise add by hand:

- **Named routes**: a `PostRoutes` enum declares each path once; the controller registers with it and builds its redirect URLs from it (`PostRoutes.show.path(item.id)`). See [Routing](routing.md#named-routes).
- **Validation with re-render**: `create` validates the input (`.required` on every field, plus `.integer`/`.decimal` for numeric ones). On failure it re-renders the New form with status 422, the submitted values repopulated (`value="{oldTitle}"`) and an inline `<span class="field-error">` message per field via `input.errors.first("title")`. The Edit form behaves the same way; the controller re-renders New/Edit at 422 with `old*`/`*Error` filled. See [Forms](forms.md).
- **Flash messages**: create/update/destroy redirect with `.flash("Post created")` (and "updated" / "deleted"), and the Index view renders the `.flash` banner. See [Routing](routing.md#flash-messages).

It writes the migration file too, then prints the route to register:

```swift
app.resources("posts", PostController())
```

The generator requires the `database` capability. Run `plumekit migrate` and the migration is picked up automatically.

## auth

Authentication is the same work in every app, so the `auth` generator scaffolds a complete email + password flow. It works for **both browser sessions** (a signed, HTTP-only cookie) **and API clients** (a bearer token). Identity resolves the same way for both, so every route serves both kinds of client:

```sh
plumekit generate auth
```

It creates:

- The `User`, `PasswordReset` and `EmailVerification` models in `Sources/App/Models/`; the `users` table is the source of truth.
- `Sources/App/Controllers/Auth.swift`: the authenticator, session manager and an `AuthController` with **register / login / logout / forgot-password / reset / verify**.
- The four page views in `Views/Auth/`.
- The two email bodies in `Views/Emails/` (verification + password reset; emails are their own kind of view, so they get their own folder).

It prints the migrations and the wiring steps:

1. Enable the `kv`, `database` and `secrets` capabilities in `plumekit.toml` (secrets backs `AUTH_SECRET`; the generator offers to flip them for you).
2. Call `installAuth(app)` in `buildApp()`; it registers the identity middleware and the routes (`/register`, `/login`, `/logout`, `/forgot`, `/reset`, plus `GET /verify` and `POST /verify/resend`).
3. Set `AUTH_SECRET` (`wrangler secret put AUTH_SECRET`, or your env) before deploying.
4. Run `plumekit migrate` (the migration file is auto-discovered).

In any handler, `request.currentUser` is the signed-in user id and `request.isAuthenticated` the flag. A browser gets a session cookie and a redirect; a client sending `Accept: application/json` gets `{"token": "…"}` and passes it back as `Authorization: Bearer …`.

Forgot-password stores a one-time token and emails the reset link as a Plume-view email (`Views/Emails/ResetEmail.plume`) when the [mailer](mailer.md#plume-view-email-bodies) is bound. In local dev, with no mailer, the link is logged instead.

The scaffold builds on the primitives in [Auth](auth.md), which you can drop down to for OAuth, policies and so on.

### Email verification

Verification is scaffolded in: registration creates an `EmailVerification` token and emails the link as a **Plume-view email** (`Views/Emails/VerifyEmail.plume`; see [Mailer](mailer.md#plume-view-email-bodies)). Without a mailer binding the link is logged, so dev keeps working. The flow itself (the verify and resend routes, the 24-hour expiry, gating routes with `requireVerified`) is described in [Auth](auth.md#email-verification).

## notifications

The `notifications` generator scaffolds two-channel notifications: an in-app inbox plus email when the mailer is bound:

```sh
plumekit generate notifications
```

It creates a `UserNotification` `@Model` (the inbox) and a `notify(userID:email:title:body:)` helper that writes the inbox row and also emails when the [mailer](mailer.md) capability is bound. Read a user's inbox with `UserNotification.for(userID)` and mark entries read with `markRead()`. The migration file is written for you and picked up on the next `plumekit migrate`.

## model & migration

To add a model without the full resource scaffold, generate just the model:

```sh
plumekit generate model Post title:string views:int published:bool
```

This writes the `@Model` and a migration file that creates its table. For a schema change not tied to a new model, `generate migration <Name>` writes a blank migration file. Both land under `Database/Migrations/` and run automatically. See [Migrations](migrations.md).

## controller, view, middleware, job, seeder

Each of the remaining generators writes one file and prints how to wire it:

```sh
plumekit generate controller Post       # → app.resources("posts", PostController())
plumekit generate view Sidebar          # → Views/Sidebar.plume
plumekit generate middleware RateLimit  # → app.use(RateLimitMiddleware())
plumekit generate job SendEmail         # → Sources/App/Jobs/SendEmailJob.swift (auto-discovered)
plumekit generate seeder Demo           # → Database/Seeders/DemoSeeder.swift; run with `plumekit seed`
```

See [Controllers](controllers.md), [Plume views](plume-views.md), [Middleware](middleware.md), [Jobs](jobs.md) and [CLI & configuration](cli.md).
