# Tutorial: build a bookmarks app

This tutorial builds a small but complete PlumeKit app: a bookmarks list you can add
to and delete from, with server-side validation. It's the shape of a real app, so
along the way you'll use the pieces you'd reach for every day:

- **routing through a controller**: the conventional RESTful actions, wired in one call,
- **Plume views**: HTML templates split across files, with a shared layout,
- **the ORM**: an `@Model` type, explicit migrations, typed queries,
- **forms**: reading a POST, validating it and re-rendering errors,
- **flash messages**: a one-time notice after a redirect.

It should take about 20 minutes. Every snippet is copy-paste-ready. If you just want
the reference for each feature, browse the docs sidebar; this page is the hands-on
path.

> **Prerequisites:** a Swift 6.3 toolchain (`swift --version`). You'll run the
> `plumekit` CLI, either the `./plumekit` wrapper in a scaffolded project (it
> downloads the matching release for you) or a local build of the framework. See
> [Getting started](getting-started.md#install-the-cli).

## 1. Scaffold and run

Create the app and start it:

```sh
plumekit new bookmarks
cd bookmarks
./plumekit dev
#   → native server on http://127.0.0.1:8080, restarting on every change
```

`plumekit new` asks a few questions. Turn **database** on when it asks about
capabilities (space toggles it); accept the defaults for everything else. Open
<http://127.0.0.1:8080/> and you'll see the starter page. Leave `dev` running in this
terminal; it rebuilds and restarts whenever you save a file.

Take a quick look around:

```txt
bookmarks/
  Package.swift              # the SwiftPM manifest
  plumekit.toml              # capabilities + per-target config
  plumekit                   # the CLI wrapper (commit it; it pins the version)
  Sources/App/
    App.swift                # buildApp(): your routes and middleware
    Database/Database.swift  # runMigrations() and runSeed()
  Views/
    Layout.plume             # the shared page shell (a component with a slot)
    HomePage.plume           # a page that fills the layout
```

Everything runs through `buildApp()` in `Sources/App/App.swift`. The native server
and the Cloudflare Worker both call it, so your app behaves identically on each.

## 2. A model and a migration

Define the data first. Create `Sources/App/Models/Bookmark.swift`:

```swift
import PlumeORM

@Model
final class Bookmark: Model {
    var id: Int          // the primary key, by convention
    var title: String
    var url: String
}
```

`@Model` reads the type at compile time and emits the table schema, a row codec and
typed query columns. The table name is the pluralised, snake-cased type name: here,
`bookmarks`.

Migrations are individual files under `Sources/App/Database/Migrations/`. They run in
filename order and are discovered automatically, you don't register them anywhere.
Create one:

```sh
./plumekit generate migration CreateBookmarks
#   + Sources/App/Database/Migrations/20260101120000_CreateBookmarks.swift
```

Open that file and describe the change explicitly with the schema builder. Spelling
the columns out keeps the migration a frozen record: editing the `Bookmark` model
later never rewrites it.

```swift
import PlumeORM

let createBookmarks = Migration(
    version: "20260101120000_create_bookmarks",
    up: { db in
        try await db.createTable("bookmarks") { t in
            t.id()
            t.text("title")
            t.text("url")
        }
    },
    down: { db in try await db.dropTable("bookmarks") }
)
```

The builder covers creating, altering, renaming and dropping tables, columns,
foreign keys and indexes. For anything it doesn't, run `db.query("...")` directly.

Apply it:

```sh
./plumekit migrate
#   plumekit migrate: applied 1 change(s)
#     + 20260101120000_create_bookmarks
```

The `Migrator` records what has run in a `schema_migrations` ledger, so re-running is
a no-op. See [Migrations](../migrations.md) for altering tables, rollbacks and
seeders.

## 3. A page, split across view files

PlumeKit's view layer is **Plume**: `.plume` templates that compile to render
functions your handlers call. Split views across files: a shared **layout** plus one
file per page. The scaffold already set up `Views/Layout.plume` as the page shell,
where `@slot` is the hole a page's content fills:

```plume
@component Layout(title: String) {<!doctype html>
<html>
  <head><title>{title}</title></head>
  <body><main>@slot</main></body>
</html>}
```

Create the bookmarks page, `Views/BookmarksPage.plume`. It takes the list to show and
an optional error message, and calls `@Layout` for the shell:

```plume
@component BookmarksPage(bookmarks: [Bookmark], error: String = "") {@Layout(title: "Bookmarks") {
  <h1>Bookmarks</h1>

  @if error != "" {
    <p class="error">{error}</p>
  }

  <form method="post" action="/bookmarks">
    @csrf
    <input name="title" placeholder="Title">
    <input name="url" placeholder="https://example.com">
    <button type="submit">Add</button>
  </form>

  @if bookmarks.size > 0 {
    <ul>@for bookmark in bookmarks {
      <li>
        <a href="{bookmark.url}">{bookmark.title}</a>
        <form method="post" action="/bookmarks/{bookmark.id}" style="display:inline">
          @csrf
          <input type="hidden" name="_method" value="delete">
          <button type="submit">×</button>
        </form>
      </li>
    }</ul>
  } else {
    <p>No bookmarks yet.</p>
  }
}}
```

A few things to notice:

- `{title}` and `{bookmark.title}` are **HTML-escaped by default**, so untrusted
  values are safe. `@if` / `@for` are control flow.
- `@csrf` renders the hidden token that form protection (on by default) checks on
  every POST. It's automatic: nothing to pass into the view, nothing to wire up in
  the handler.
- HTML forms can only GET or POST, so the delete form POSTs with a hidden
  `_method=delete` field; PlumeKit routes it to the controller's `destroy` action.

See [Components](../components/index.md) and [Syntax](../syntax/index.md) for the full
language.

## 4. A controller

Rather than scatter closures in `buildApp()`, group the bookmark actions in a
controller. Create `Sources/App/Controllers/BookmarksController.swift`:

```swift
import PlumeCore
import PlumeRuntime
import PlumeORM

struct BookmarksController: Controller {
    // GET /bookmarks: list newest first and show the add form.
    func index(_ request: Request) async throws -> Response {
        let bookmarks = try await Bookmark.all().order(by: Bookmark.id, .descending).all()
        return .view(bookmarksPage(bookmarks: bookmarks))
    }

    // POST /bookmarks: add one, or re-render the form with an error.
    func create(_ request: Request) async throws -> Response {
        let title = request.form["title"] ?? ""
        let url = request.form["url"] ?? ""
        if title.isEmpty || url.isEmpty {
            let bookmarks = try await Bookmark.all().order(by: Bookmark.id, .descending).all()
            return .view(bookmarksPage(bookmarks: bookmarks,
                                       error: "Title and URL are both required."))
        }
        _ = try await Bookmark(title: title, url: url).save()
        return .redirect(to: "/bookmarks").flash("Bookmark added")
    }

    // DELETE /bookmarks/:id removes one.
    func destroy(_ request: Request) async throws -> Response {
        if let bookmark = try await Bookmark.find(request) {
            try await bookmark.delete()
        }
        return .redirect(to: "/bookmarks")
    }
}
```

`Controller` gives every action a default "405 Method Not Allowed", so you implement
only the three you need. Inside a handler, ORM calls use the current request's
database automatically. `Bookmark.find(request)` reads the `:id` route parameter and
loads the row (or returns nil). `.flash(_:)` attaches a one-time message to the
redirect, which we'll show next.

## 5. Wire it up

Routes live in `Sources/App/Routes.swift`. Open it and register the controller.
`app.resources` maps the conventional RESTful routes to the controller's actions in
one call:

```swift
import PlumeCore
import PlumeRuntime

func registerRoutes(_ app: Application) {
    app.get("/") { _ in .redirect(to: "/bookmarks") }
    app.resources("bookmarks", BookmarksController())
}
```

`resources("bookmarks", …)` wires `GET /bookmarks` → `index`, `POST /bookmarks` →
`create` and `DELETE /bookmarks/:id` → `destroy` (plus `show`/`update` if you add
them). Replace the starter `/`, `/hello` and `/count` demo routes with these two,
and delete the now-unused `Views/HomePage.plume`. CSRF protection is already wired in
`buildApp()` (`App.swift`), so there's nothing to add there.

To show the "Bookmark added" flash, render it in the layout so every page picks it
up. Edit `Views/Layout.plume`:

```plume
@component Layout(title: String, flash: String = "") {<!doctype html>
<html>
  <head><title>{title}</title></head>
  <body><main>
    @if flash != "" { <p class="flash">{flash}</p> }
    @slot
  </main></body>
</html>}
```

Then forward the flash from the page. In `Views/BookmarksPage.plume`, add a `flash`
parameter and pass it to `@Layout`:

```plume
@component BookmarksPage(bookmarks: [Bookmark], error: String = "", flash: String = "") {@Layout(title: "Bookmarks", flash: flash) {
```

and hand it in from `index`:

```swift
return .view(bookmarksPage(bookmarks: bookmarks, flash: request.flash?.message ?? ""))
```

## 6. Run it

`./plumekit dev` already rebuilt on each save. Open
<http://127.0.0.1:8080/bookmarks>, add a bookmark with the form, and it appears in
the list with a "Bookmark added" notice. Submit with an empty field and the form
comes back with the error. Click × to delete. That's the full loop: a controller
renders a Plume view, forms POST to actions, validation re-renders, and the ORM
persists.

If a handler throws while you're developing, `dev` shows a full error page (the
error, the request and your route table) instead of a bare 500. In production it's a
clean 500.

## Where to go next

You've used the core of PlumeKit. From here:

- **Validation rules**: declare them on the model so `save()` enforces them. See
  [Validations](../validations.md).
- **Pagination**: `Bookmark.all().paginate(page: 1, per: 20)` returns a `Page` with
  `nextURL`/`previousURL` and totals. See the [ORM](../orm.md).
- **Auth**: `plumekit generate auth` scaffolds registration, login and sessions. See
  [Auth](../auth.md).
- **Deploy it**: `./plumekit deploy` builds and ships to your configured target
  (Cloudflare Worker, AWS Lambda or a container). See [Deploying](../deploying.md).

The same app you just built runs unchanged on the native server and on Cloudflare;
see [Portability](../portability.md).
