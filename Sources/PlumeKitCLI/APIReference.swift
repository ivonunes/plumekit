// Curated, accurate PlumeKit API reference, embedded so `plumekit mcp`'s
// `api_reference` tool works offline in any project. Keep these examples correct —
// they are what an AI agent relies on for PlumeKit's APIs.
enum APIReference {
    static let topics: [String: String] = [
        "overview": """
        PlumeKit is a native Swift web framework. You write an app once as `buildApp() -> Application`;
        the same code runs natively (`plumekit serve`), as a Cloudflare Worker (Wasm), and as an AWS
        Lambda. Host capabilities (database, KV, storage, cache, queue, secrets, HTTP, mail) are reached
        through `request.bindings.<name>`, enabled in `plumekit.toml`. Views use the Plume templating
        language (`.plume` files → generated render functions). Key modules: PlumeCore (framework),
        PlumeORM (@Model), PlumeRuntime (Plume render runtime). Topics: routing, request, response, orm,
        migrations, forms, views, capabilities, i18n, schedule, helpers, testing, cli, config, portability.
        """,

        "portability": """
        Your handlers, models, and views compile to Embedded-Swift Wasm for the Cloudflare target. Rules
        for code YOU write (every framework API is already safe on all targets):
        • Native String operations WORK in the guest: ==, !=, hasPrefix/hasSuffix, lowercased()/uppercased(),
          split(separator:), Dictionary<String, _>, and Character/grapheme iteration — with FULL Unicode
          semantics (canonical equivalence, real case mapping). `plumekit build --target cloudflare` links
          Swift's Unicode data tables into the Wasm build automatically (no opt-in; ~40 KB compressed when
          used, well within Workers' 3 MB free / 10 MB paid / 64 MB uncompressed limits). Framework internals
          still compare bytes (Plume.equal, utf8Equal) to stay minimal — reach for those only in a
          size-critical hot path where you want to avoid pulling the tables.
        • No Foundation, no runtime reflection (Mirror), no Codable/JSONEncoder — PlumeKit's JSON, row codec,
          and form parsing are explicit for this reason. No regex (use byte scanning / String methods).
        • 32-bit Int in the guest — use Int64 for values that may exceed 2^31 (e.g. epoch milliseconds;
          @Model enforces Int64 timestamps).
        • `import _Concurrency` is required in any file using async.
        The native (`plumekit serve`) and AWS Lambda targets have none of these limits — this is only the
        Cloudflare/Wasm target.
        """,

        "routing": """
        Register routes on `Application` with method helpers; a handler is an `async throws` closure
        `(Request) -> Response`:

            public func buildApp() -> Application {
                let app = Application()
                app.get("/") { _ in .text("hello") }
                app.get("/hello/:name") { request in
                    .text("Hello, \\(request.parameters["name"] ?? "world")!")
                }
                app.post("/posts") { request in … }
                return app
            }

        Helpers: get, post, put, patch, delete, head, options, and `on(_ method:_ path:_ handler:)`.
        `:name` captures a path segment into `request.parameters`. Wildcards: `*path` (one-or-more
        segments) / `**path` (zero-or-more) capture the rest of the path (no regex — not Wasm-linkable).
        Named routes — declare a path once, register AND build URLs from it (param count is typed):
            enum PostRoutes { static let index = Route("/posts"); static let show = Route1("/posts/:id") }
            app.get(PostRoutes.show) { … }
            return .redirect(to: PostRoutes.show.path(post.id))   // "/posts/42"
        Route model binding: `guard let post = try await Post.find(request) else { return .status(404) }`
        (reads `:id`; `parameter: "post_id"` for nested routes).
        Groups + scoped middleware (nest to compose):
          app.group("/admin", middleware: [requireAdmin]) { admin in admin.resources("posts", PostController()) }
        Global middleware: `app.use { request, next in try await next(request) }`. Built-ins:
        `methodOverride()`, `csrfProtection()`, `identityMiddleware(_:)`, `requireAuth(redirectTo:)`
        (put a group behind a login — `app.group("/admin", middleware: [requireAuth()]) { … }`; needs
        identityMiddleware earlier; browsers get a redirect, bearer-token clients get 401).
        """,

        "request": """
        `Request` (passed to every handler):
          • request.method            — HTTPMethod (.get, .post, …); .name is the string.
          • request.path              — String
          • request.parameters["x"]   — path params (String?)
          • request.queryParams["x"]  — parsed query string (String?)
          • request.form["x"]         — urlencoded form field (String?)
          • request.body              — [UInt8]; request.bodyText — String
          • request.decode(T.self)    — typed decode of urlencoded/multipart fields
          • request.multipart()       — multipart form (file uploads → storage)
          • request.bindings.<cap>    — typed capability handle (see `capabilities`)
          • request.context.log(_:)   — log line (stdout / console.log)
        """,

        "response": """
        `Response` factories:
          • .text(_ string: String, status: Int = 200)
          • .html(_ string: String, status: Int = 200) / .html(bytes: [UInt8], status:)
          • .json(_ string: String, status:) / .json(_ value: JSONValue, status:)
          • .redirect(to: String, status: Int = 303)
          • .status(_ status: Int)
          • Response(body: [UInt8], status:)
        The scaffold adds `.view(_ html: HTML)` (via a PlumeView extension) to return a rendered Plume
        buffer. Handlers `throw` → 500 (under `plumekit serve`/`dev` — PLUMEKIT_ENV=development — the
        native server renders a full dev error page instead; production stays a clean 500).
        Flash messages (one-time, shown after a redirect, auto-cleared by the framework):
          • .redirect(to: "/posts").flash("Post created")          — set (kinds: Flash.notice/success/error/warning)
          • request.flash?.message / ?.kind                        — read on the next page view
        API transformers: conform a model to `JSONRepresentable` (explicit `jsonValue`) and return
        `.json(post)` / `.json(posts)` / `.json(page)` (a Page adds limit/offset/hasMore metadata).
        """,

        "orm": """
        Define a model with the `@Model` macro (module PlumeORM). The table name is the pluralized,
        snake_cased type name (`Post` → `posts`). `id: Int` is the primary key by convention (Int, Int64,
        or UUID supported).

            import PlumeORM
            @Model final class Post: Model {
                var id: Int
                var title: String
                var published = false
            }

        Inside a handler, ORM calls use the current request's database automatically — no `in:`:
        Persistence:
          • try await post.save()            — INSERT/UPDATE; populates id; returns [ValidationError]
          • try await post.upsert()
          • try await post.delete()
          • try await Post.find(id)          — Post?
        Typed query builder:
          • Post.all()                       — a Query
          • Post.where(Post.published == true && Post.views > 5)
          • .order(by: Post.id, .descending)
          • .limit(10)
          • try await query.all()            — [Post]
          • try await query.count()          — Int
          • try await query.paginate(page: 2, per: 20, withTotal: true)  — Page: items, page,
            nextPage/previousPage, nextURL(_:)/previousURL(_:), total/totalPages (when counted),
            hasMore. Return with `.json(page)` for the standard envelope (+ total/page when counted)
        The database is ambient in migrations, seeders, and background jobs too — the only place you pass
        it explicitly is a test: `post.save(in: db)`, `Post.all().all(in: db)`.
        A wrong-type predicate (e.g. Post.published > 5) is a COMPILE error. Relationships: @BelongsTo /
        @HasMany with `try await post.$comments.load(in: db)`. Relations work with any primary-key type
        (Int, UUID, String) — the FK stores the parent's raw key; read `$post.id` (Int FK) or `$post.key`
        (raw SQLValue).

        Transactions (native SQLite/Postgres; D1 has none — each statement is atomic on its own):
            let order = try await db.transaction { tx in
                _ = try await order.save(in: tx)          // ambient ORM calls also join the transaction
                _ = try await tx.query("UPDATE …", […])
                return order                               // a thrown error rolls everything back
            }
        Soft deletes: conform to `SoftDeletable` (+ a `var deletedAt = 0` column). Queries and `find`
        hide trashed rows automatically; `post.softDelete()` / `.restore()` / `.forceDelete()`;
        `Post.withTrashed()` / `Post.onlyTrashed()` / any-query `.unscoped()`.
        Query scopes: `static var defaultScope: Predicate<Self>?` on a model pre-filters every query.
        Lifecycle callbacks (override on the model; no-ops by default): `willSave` (after validation,
        before the write — mutate fields, e.g. derive a slug), `didSave`, `willDelete` (throw to abort),
        `didDelete`.
        """,

        "migrations": """
        Versioned schema changes as individual files under Sources/App/Database/Migrations/, discovered
        automatically (run in filename order, no manual registration). Scaffold one with
        `plumekit generate migration CreatePosts`, then describe the change explicitly with the schema
        builder — spelled out, NOT derived from the model, so it's a frozen record:

            import PlumeORM
            let createPosts = Migration(
                version: "20260101120000_create_posts",
                up: { db in
                    try await db.createTable("posts") { t in
                        t.id(); t.text("title"); t.integer("views"); t.timestamps()
                    }
                },
                down: { db in try await db.dropTable("posts") }
            )

        Builder: t.text/integer/real/boolean/uuid/blob(name, nullable:), t.id(), t.references("author",
        table: "users"), t.timestamps(); db.alterTable("posts") { t in t.addColumn/dropColumn/renameColumn },
        db.addIndex/dropIndex/renameTable/dropTable. For anything it doesn't cover, run db.query("...")
        or use Migration.sql(version:up:down:). Do NOT use Model.createTable in a migration (that reads the
        live model and drifts) — it's for tests/dev only. Apply with `plumekit migrate` (native) or
        `--local`/`--remote` (Cloudflare D1). Seeders: files under Database/Seeders/ (`Seeder { db in … }`),
        also auto-discovered; `plumekit seed` runs all, `plumekit seed <name>` runs one. Rollback/status are
        Swift APIs on Migrator(plumeKitMigrations). Migrator tracks a `schema_migrations` ledger; re-running is a no-op.
        """,

        "forms": """
        Read urlencoded fields with `request.form["field"]` (String?). Validate input (form OR JSON):
          let v = request.validate([("email", [.required, .email]), ("age", [.required, .integer, .min(18)])])
          guard v.isValid else { return .json(v.errors.jsonValue, status: 422) }   // then v.string("email"), v.int("age")
        Rules: .required/.email/.integer/.decimal/.min/.max/.minLength/.maxLength/.oneOf/.sameAs/.check(msg,pred).
        Re-render on failure with old input + inline errors (what `generate resource` scaffolds):
            guard input.isValid else {
                return .view(postIndex(…, oldTitle: input.string("title"),
                                       titleError: input.errors.first("title")), status: 422)
            }   // `errors.first(field)` is "" when clean — template-friendly for @if.
        Typed decode: `request.decode(MyForm.self)`. File uploads: `request.multipart()` →
        `form.upload(to: request.bindings.storage)`.
        CSRF is ON by default in scaffolded apps (csrfProtection() + a CSRF_SECRET in .env; JSON/bearer
        exempt). Put `@csrf` inside any `<form>` and it renders the hidden token field automatically —
        no parameter to thread, no handler wiring. For fetch POSTs, send `request.csrfToken()` as the
        X-CSRF-Token header. Baseline: no-JS `<form method="post">` → handler → `.redirect(to:)`.
        """,

        "views": """
        Views are Plume `.plume` templates that compile to render functions. Split across files: a shared
        Layout + one file per page. `plumekit compile Views -o Sources/App/Generated` (run by
        new/serve/build) generates one Swift file per template.

            // Views/Layout.plume
            @component Layout(title: String) {<!doctype html><html><head><title>{title}</title></head>
            <body><main>@slot</main></body></html>}

            // Views/PostsPage.plume
            @component PostsPage(posts: [Post]) {@Layout(title: "Posts") {
              <ul>@for post in posts {<li>{post.title}</li>}</ul>
            }}

        A `@component Name(args)` generates `func name(args…, into out: inout HTML)`. `{expr}` outputs
        (HTML-escaped by default); `@if`/`@for` are control flow; `@slot` is the trailing content. Render
        from a handler: `return .view(postsPage(posts: posts))` (each component also has an
        `into: &out` form used to compose components into a shared buffer).
        """,

        "capabilities": """
        Host capabilities are declared in plumekit.toml's [capabilities]. Inside a handler, reach each
        one ambiently via `.current` — no `request` threading, the same way the ORM uses the request's db:
          • database → the ORM (`Post.all()`), or raw SQL: try await Database.current.query(sql, params).
          • KV.current      → getString(key) / putString(key, value) / get / put ([UInt8]).
          • Cache.current   → get(key) / set(key, bytes, ttlSeconds:) / delete(key).
          • Storage.current → get / put / delete(key, bytes); .serve(key, contentType:) → Response
                              (stream a stored object, e.g. an upload; 404 if missing).
          • Queue.current   → send(bytes); typed jobs via Job.enqueue(on:).
          • Secrets.current → secret(name) ([UInt8]?) / has(name).
          • HTTP.current    → get(url) → FetchResponse(status, body).
          • Mailer.current  → send(EmailMessage(from:to:subject:textBody:)).
        The typed `request.bindings.<cap>` still works too (a COMPILE error if the capability isn't
        enabled). The same handler code runs on every target; drivers are selected per target in plumekit.toml.

        Static files: drop assets in the project's `Public/` directory — served at `/` by the native
        server, and by the platform on the edge (Cloudflare `[assets]`; the build copies `Public/`).
        Reference build-fingerprinted assets from a template with `asset("app.js")` / `asset("logo.png")`
        (resolved to the content-hashed URL at build time). Views opting into client navigation via
        `@navigation` get the runtime `<script>` injected automatically — no manual tag.
        """,

        "schedule": """
        Scheduled tasks — the same code on every target; only the ticker differs (native minute timer,
        a Cloudflare Cron Trigger `crons = ["* * * * *"]`, an EventBridge 1-minute rule). All times UTC.
        Declared in ONE place, `registerSchedules(_ schedule:)` in Sources/App/Schedules.swift (its own
        file, like Routes.swift):
            schedule.task("prune-sessions", every: .hourly()) { context in … }
        Cadences: .minute, .minutes(n), .hourly(atMinute:), .daily(hour:minute:). Due-ness is matched
        statelessly against the wall clock (cron semantics — a missed tick is skipped, not replayed;
        for must-not-lose work have the task enqueue a Job). Failures are logged and don't block other
        tasks. Plumbing is GENERATED: `buildSchedule()` wraps registerSchedules, and buildJobs() does
        `registry.include(buildSchedule())`, so the tick is a registered job on the queue-backed targets
        and PlumeServer.run(schedule:) ticks it natively. Jobs themselves are AUTO-discovered from
        Sources/App/Jobs/ (any depth) — no manual registration; `plumekit generate job Foo` scaffolds one.
        """,

        "i18n": """
        Translations resolve the request's language once so handlers and views call `t("key")` with no
        locale threaded through. Strings live in Translations/<locale>.json (flat {"key":"value"} maps),
        compiled into `plumeKitTranslations` automatically; the fallback language is `[i18n] default` in
        plumekit.toml. Scaffolded apps register `app.use(localization(plumeKitTranslations))` in buildApp().
            // handler:  t("greeting", ["name": user.name])
            // view:     {t("welcome.title")}   or   {t("greeting", name: user.name)}
        Placeholders `{name}` fill from the params; a missing key renders the key itself. Language order:
        ?lang= query → `locale` cookie → Accept-Language → default. Override for a signed-in user's saved
        preference with `useLocale("pt")`; read the active one with `currentLocale`. In an @script block
        `t("key")` works in the COMPILED build (the framework injects the active locale's strings); under
        the interpreter `t` is undefined, so translate in the view and read a data-attribute in the script.
        """,

        "helpers": """
        Signed URLs (links that authenticate themselves — unsubscribe, downloads, invites):
          • SignedURL.sign("/unsubscribe?user=42", key: key, expiresAt: epochSeconds?) → path+sig
          • SignedURL.verify(request, key: key, nowEpochSeconds: now) → Bool (HMAC-SHA256, constant-time;
            tampering with path, params, or expiry fails).
        Localization (compiled-in translations, no ICU):
          • let t = Translations(default: "en", ["en": ["k": "v"], "pt": […]])
          • t.t("welcome.title", locale: locale)  — requested → default → key fallback
          • request.preferredLanguage(available: ["en", "pt"]) — Accept-Language negotiation ("pt-BR" → "pt").
        Email with a Plume-view body (scaffold's Mailer extension):
          • try await Mailer.current.send(to:, subject:, view: welcomeEmail(name: …), text: fallback)
        Auth extras (generate auth): email verification (GET /verify, POST /verify/resend,
        `requireVerified(request)` guard, `User.verifiedAt`). Notifications (generate notifications):
        `notify(userID:email:title:body:)` → in-app inbox row (`UserNotification.for(userID)`) + email
        when the mailer is bound.
        """,

        "cli": """
        `plumekit` commands (use the committed `./plumekit` wrapper in a project):
          new <name>        scaffold (interactive)      serve [path]      run natively
          dev [path]        serve + watch/restart       console [path]    REPL
          migrate / seed    [--local|--remote] for D1   routes [path]     list routes
          generate <resource|auth|notifications|model|controller|migration|view|middleware|job|seeder|test|ci> …
          test [path]       run tests
          doctor            check the toolchain         build [--target cloudflare|aws|native|all]
          deploy [--target …] [--skip-migrations|--seed]  migrate→(seed→)build→deploy
          compile|check|format|bundle  Plume templating (recurse into a directory)
        """,

        "config": """
        plumekit.toml — the project manifest:
          [capabilities]  kv/database/storage/cache/queue/http/secrets = true|false (compile-time gate)
          [build]         default = "cloudflare"; targets = ["cloudflare","aws"]; out = "dist"
          [deploy]        migrate = true; seed = false  (what `plumekit deploy` runs)
          [targets.native]     database = "sqlite"|"postgres"; storage = "filesystem"|"memory"|"s3"
          [targets.cloudflare] database = "d1"; storage = "r2"
          [targets.aws]        database = "postgres"; storage = "s3"; kv/cache = "dynamodb"; queue = "sqs"; secrets = "ssm"
        Enabling a capability generates `request.bindings.<cap>`. Switching a driver + rebuilding relinks a
        different adapter with no app-code change.
        """,

        "testing": """
        Tests run natively with Swift Testing; `import PlumeTesting` (re-exports PlumeCore + PlumeORM),
        `@testable import App`. Each test boots a fresh, migrated in-memory database + a TestHTTPClient:
            let app = try await TestApp.boot(buildApp, migrations: runMigrations)
            _ = try await Post.factory.create(in: app.database)
            let response = await app.client.get("/posts")
            #expect(response.hasStatus(200) && response.bodyContains("…"))
        Factories (PlumeORM, usable in seeders too): `extension Post { static let factory = Factory { Post(title: "x") } }`;
        `.make()` (unsaved), `.create(in:)`, `.createMany(n, in:)`, with `{ $0.field = … }` overrides. Unique
        values: `Fake.email()/int()/string()/hex()/bool()`. Response assertions: `.hasStatus(_)`, `.isOK`,
        `.isRedirect`, `.bodyContains(_)`, `.header(_)`, `.decodedJSON()`. Form POSTs need the CSRF token:
        `postForm("/posts", "_csrf=\\(app.csrfToken)&title=x")`. Client: get/post/put/patch/delete,
        `post(_, json:)`, `postForm(_, _)`, headers via `.bearer(token)`. Run with `plumekit test`. Generate
        tests: `plumekit generate test <Name>` (and `generate resource` emits a factory + test).
        """,
    ]
}
