import PlumeCore
import PlumeORM
import PlumeRuntime

/// Build the application. Both the native server and the Wasm worker call this,
/// so the same async routes run in both runtimes — including the KV-backed ones,
/// which hit a native store under `plumekit serve` and Workers KV on the edge,
/// and the Plume-rendered HTML view (the `/page` route).
public func buildApp() -> Application {
    let app = Application()

    // Request logging via the platform log seam (→ console.log on Workers,
    // stdout natively). Replaces v0's `print`, which bloated the wasm.
    app.use { request, next in
        let response = try await next(request)
        request.context.log("\(request.method.name) \(request.path) -> \(response.status)")
        return response
    }

    // Form middleware: _method override (HTML forms only GET/POST) + CSRF on
    // form/multipart submissions (JSON APIs are exempt — they use token auth).
    app.use(methodOverride())
    app.use(csrfProtection())
    app.use(identityMiddleware())   // resolve currentUser from cookie or bearer (AUTH_SECRET + KV)
    registerAuthRoutes(app)             // /auth/register, /auth/login, /auth/logout, /auth/me
    registerAPIRoutes(app)              // /api/v1 (token-only, paginated, structured errors)
    registerSyncRoutes(app)             // /api/v1/sync/notes (delta + idempotent intents)

    app.get("/") { _ in
        .text("Hello from PlumeKit")
    }

    app.get("/hello/:name") { request in
        let name = request.parameters["name"] ?? "world"
        return .text("Hello, \(name)!")
    }

    // KV-backed visit counter — identical code native and on Workers.
    app.get("/count") { request in
        let kv = request.bindings.kv
        let current = (await kv.getString("counter")).flatMap { Int($0) } ?? 0
        let next = current + 1
        await kv.putString("counter", String(next))
        return .text("count=\(next)")
    }

    // Read / write arbitrary keys.
    app.get("/kv/:key") { request in
        let kv = request.bindings.kv
        let key = request.parameters["key"] ?? ""
        guard let value = await kv.get(key) else { return .text("(not found)", status: 404) }
        return Response(body: value)
    }

    app.put("/kv/:key") { request in
        let kv = request.bindings.kv
        let key = request.parameters["key"] ?? ""
        await kv.put(key, request.body)
        return .text("stored \(request.body.count) bytes at \(key)")
    }

    // Ephemeral cache — a TTL'd counter. Identical code on the native in-memory
    // cache and a Workers-KV cache; a `get` may miss, so we default to 0.
    app.get("/cache") { request in
        let cache = request.bindings.cache
        let previous = (try? await cache.getString("hits")) ?? nil
        let next = (previous.flatMap { Int($0) } ?? 0) + 1
        try await cache.setString("hits", String(next), ttlSeconds: 60)
        return .text("cache hits=\(next) (expires in 60s)")
    }

    // A Plume-rendered HTML page. The render function `page(...)` is generated
    // from Views/Views.plume by `plume compile` (run by `plumekit build`/serve).
    // The "<World>" item shows Plume's default HTML escaping flowing through.
    app.get("/page") { _ in
        let items = [
            Item(name: "alpha"),
            Item(name: "Hello & <World>"),
            Item(name: "gamma"),
        ]
        var out = HTML()
        page(title: "PlumeKit + Plume", items: items, into: &out)
        return .view(out)
    }

    // SQL database — identical code on Cloudflare D1 and native SQLite. Each call
    // appends a post and lists them, returning typed rows.
    app.get("/posts") { request in
        let db = request.bindings.database
        do {
            try await db.query(
                "CREATE TABLE IF NOT EXISTS post(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, views INTEGER NOT NULL)")
            let countResult = try await db.query("SELECT COUNT(*) AS n FROM post")
            let n = intCell(countResult.rows.first?.first) ?? 0
            try await db.query(
                "INSERT INTO post(title, views) VALUES(?, ?)",
                [.text("Post #\(n + 1)"), .integer((n + 1) * 10)])
            let result = try await db.query("SELECT id, title, views FROM post ORDER BY id")
            return .text(renderRows(result))
        } catch {
            return .text("db error", status: 500)
        }
    }

    // Blob storage — same code on Cloudflare R2 and the native filesystem.
    app.put("/blob/:key") { request in
        let storage = request.bindings.storage
        let key = request.parameters["key"] ?? ""
        try await storage.put(key, request.body)
        return .text("stored \(request.body.count) bytes at \(key)")
    }
    app.get("/blob/:key") { request in
        let storage = request.bindings.storage
        let key = request.parameters["key"] ?? ""
        guard let bytes = try await storage.get(key) else { return .text("(not found)", status: 404) }
        return Response(body: bytes)
    }

    // Enqueue a message — Cloudflare Queues or the native in-process queue.
    app.get("/enqueue") { request in
        let queue = request.bindings.queue
        try await queue.send("hello-job")
        return .text("enqueued")
    }

    // Jobs — enqueue a typed job; the consumer (Cloudflare queue consumer or
    // the native drainer) runs it and records the result in KV.
    app.get("/job/enqueue") { request in
        let message = request.queryParams["message"] ?? "hello-from-route"
        try await LogJob(message: message).enqueue(on: request.bindings.queue)
        return .text("enqueued job: \(message)")
    }
    app.get("/job/last") { request in
        let last = await request.bindings.kv.getString("last-job") ?? "(none yet)"
        return .text("last-job=\(last)")
    }

    // Broadcast origination points (all render with NO request in scope):
    // (a) from a JOB: enqueue a job whose perform renders + broadcasts.
    app.get("/broadcast-job") { request in
        let room = request.queryParams["room"] ?? "lobby"
        let text = request.queryParams["text"] ?? "hello"
        try await BroadcastJob(room: room, text: text).enqueue(on: request.bindings.queue)
        return .text("enqueued broadcast for room=\(room)")
    }
    // (b) from a REQUEST handler: broadcast directly after handling.
    app.get("/broadcast-now") { request in
        let room = request.queryParams["room"] ?? "lobby"
        let text = request.queryParams["text"] ?? "hello"
        guard let broadcaster = request.context.broadcaster else {
            return .text("no broadcaster bound", status: 500)
        }
        await broadcast(room: room, text: text, "now", via: broadcaster)
        return .text("broadcast to room=\(room)")
    }
    // Signed subscriptions: mint a channel-scoped token server-side. The client
    // presents it on subscribe; the channel verifies + rejects forged/expired/wrong.
    app.get("/channel-token") { request in
        guard let secrets = request.context.secrets,
              let key = try await secrets.secret("CHANNEL_SIGNING_KEY"), !key.isEmpty else {
            return .text("no channel signing key configured", status: 500)
        }
        let room = request.queryParams["room"] ?? "lobby"
        let subject = request.queryParams["subject"] ?? "user-1"
        let expiresAt = Int(ORMClock.now() / 1000) + 3600   // valid 1 hour
        let token = ChannelToken.mint(channel: ChannelID(room), subject: subject,
                                      expiresAt: expiresAt, key: key)
        return .text(token)
    }

    // (c) MODEL-DRIVEN: a save fans the Post out to the "posts" channel via the
    // model's own Broadcastable declaration — no request passed to the renderer.
    app.get("/posts/broadcast") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let post = Post(title: request.queryParams["title"] ?? "new post", views: 0, published: true)
        let errors = try await post.save(in: db)
        if !errors.isEmpty { return .text("invalid: \(errors.count) error(s)", status: 422) }
        if let broadcaster = request.context.broadcaster {
            await broadcast(post, via: broadcaster)   // model → channel, no request
        }
        return .text("created + broadcast post id=\(post.id)")
    }

    // Outbound HTTP — Cloudflare's global fetch or the native URLSession client.
    app.get("/fetch") { request in
        let http = request.bindings.http
        let response = try await http.get("https://example.com")
        return .text("fetched status=\(response.status) bytes=\(response.body.count)")
    }

    // Secrets / config — Cloudflare secrets+vars on `env`, or native env vars.
    // Reports presence only; never echoes a secret value.
    app.get("/config/:name") { request in
        let name = request.parameters["name"] ?? ""
        let isSet = try await request.bindings.secrets.has(name)
        return .text("\(name)=\(isSet ? "set" : "unset")")
    }

    // ORM — a full save→find round-trip through the active SQLDatabase. The
    // SAME generic code runs on native SQLite (`plumekit serve`) and Cloudflare D1
    // (`wrangler dev`). Bootstraps the table (create-if-not-exists; real schema
    // changes belong in migrations).
    app.get("/orm") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let post = Post(title: "Hello & <World>", views: 7, published: true)
        _ = try await post.save(in: db)                       // INSERT, populates id
        guard let restored = try await Post.find(post.id, in: db) else {
            return .text("not found after save", status: 500)
        }
        return .text("saved id=\(post.id) title=\(restored.title) views=\(restored.views)")
    }

    // Query builder — typed where/order/limit/count, the same on SQLite and D1.
    app.get("/orm/query") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let hits = try await Post
            .where(Post.published == true && Post.views > 5)
            .order(by: Post.views, .descending)
            .limit(3)
            .all(in: db)
        let total = try await Post.count(in: db)
        return .text("matched=\(hits.count) total=\(total) top=\(hits.first?.title ?? "-")")
    }

    // Relationships — @BelongsTo / @HasMany with explicit async loading. Same
    // code on native SQLite and D1.
    app.get("/orm/rel") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        try await Comment.createTable(in: db)
        let post = Post(title: "T", views: 1, published: true)
        _ = try await post.save(in: db)
        _ = try await Comment(body: "a", post: post).save(in: db)
        _ = try await Comment(body: "b", post: post).save(in: db)
        let comments = try await post.$comments.load(in: db)
        let parent = try await comments.first?.$post.load(in: db)
        return .text("post=\(post.id) comments=\(comments.count) parent=\(parent?.id ?? -1)")
    }

    // Auto-managed timestamps — createdAt/updatedAt set from the platform clock
    // (Foundation Date natively, JS Date.now() on Workers). Returns >0 on both.
    app.get("/orm/time") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let post = Post(title: "t", views: 0, published: false)
        _ = try await post.save(in: db)
        return .text("createdAt=\(post.createdAt > 0) updatedAt=\(post.updatedAt > 0)")
    }

    // Streaming bodies — a chunked response and an unbuffered upload. The same
    // handlers run buffered on Workers/Lambda (the ABI is one blob there).
    app.get("/stream/count") { _ in
        .stream(contentType: "text/plain") { writer in
            for i in 1...5 { try await writer.write("chunk-\(i)\n") }
        }
    }
    app.post("/upload/stream", body: .streaming) { request in
        var total = 0
        while let chunk = try await request.bodyReader?.next() { total += chunk.count }
        return .text("received \(total) bytes")
    }
    // …and straight into object storage: chunks flow to the driver's sink
    // (filesystem/S3 stream; buffered drivers collect) without buffering here.
    app.post("/upload/store", body: .streaming) { request in
        guard let reader = request.bodyReader else { return .status(400) }
        try await request.bindings.storage.put("uploads/streamed.bin", from: reader)
        let stored = try await request.bindings.storage.get("uploads/streamed.bin")?.count ?? -1
        return .text("stored \(stored) bytes")
    }

    // Migrations run from the CLI (`plumekit migrate`) or the Server's --migrate
    // flag; this route just reports how many have been applied. Native-only — the
    // Migrator's throwing closures don't exist in the embedded wasm guest.
    #if !hasFeature(Embedded)
    app.get("/migrate") { request in
        let db = request.bindings.database
        let status = try await appMigrator().status(in: db)
        let applied = status.filter { $0.applied }.count
        return .text("migrations: \(applied)/\(status.count) applied")
    }
    #endif

    // Validations — save() validates first and returns the errors (persisting
    // nothing); the handler maps them to 422. Same on native SQLite and D1.
    app.get("/validate") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let invalid = Post(title: "", views: -5, published: false)
        let errors = try await invalid.save(in: db)   // returns errors; nothing persisted
        if errors.isEmpty { return .text("unexpectedly saved", status: 500) }
        var body = "422 invalid:"
        for error in errors { body += "\n" + error.field + ": " + error.message }
        return .text(body, status: 422)
    }

    // RESTful controller — index/show/create/update/destroy over the Post model.
    //   GET/POST /api/posts   ·   GET/PUT/PATCH/DELETE /api/posts/:id
    app.resources("/api/posts", PostController())

    // Multipart upload — file parts stream to the StorageDriver (filesystem / R2 /
    // S3); the handler gets a reference, not the bytes. Same code on both targets.
    app.post("/upload") { request in
        guard let form = request.multipart() else {
            return .text("expected multipart/form-data", status: 400)
        }
        let (fields, files) = try await form.upload(to: request.bindings.storage)
        var body = "fields=\(fields.values.count)"
        for file in files { body += " file:\(file.field)→\(file.key)(\(file.size)b)" }
        return .text(body)
    }

    // Form page — a real <form method="post"> with an auto-included CSRF token.
    // Works with NO JS (full POST → redirect); Plume's @navigation enhances it to a
    // fetch-and-swap when JS is present. Same handler serves both.
    app.get("/posts/new") { request in
        let form = renderPostForm(title: "", views: 0, errors: [])
        return .view(fullPage(form))
    }

    app.get("/healthz") { _ in
        .json("{\"status\":\"ok\"}")
    }

    return app
}

#if !hasFeature(Embedded)
/// The app's schema migrations, hand-authored and ordered. `up` creates each table;
/// `down` drops it. `plumekit migrate` (and the Server's --migrate flag) run these;
/// the same Migrator runs on native SQLite, D1, and Postgres. Native-only — the
/// Migrator's throwing closures don't exist in the embedded wasm guest.
public func appMigrator() -> Migrator {
    Migrator([
        Migration(
            version: "0001_create_posts",
            up:   { db in try await Post.createTable(in: db) },
            down: { db in _ = try await db.query("DROP TABLE IF EXISTS post", []) }
        ),
        Migration(
            version: "0002_create_comments",
            up:   { db in try await Comment.createTable(in: db) },
            down: { db in _ = try await db.query("DROP TABLE IF EXISTS comment", []) }
        ),
    ])
}

/// Apply pending migrations; returns the versions that ran.
public func runMigrations(in db: Database) async throws -> [String] {
    try await appMigrator().migrate(in: db)
}
#endif

private func intCell(_ value: SQLValue?) -> Int64? {
    if case .integer(let n) = value { return n }
    return nil
}

private func renderRows(_ result: QueryResult) -> String {
    var out = result.columns.joined(separator: " | ") + "\n"
    for row in result.rows {
        var cells: [String] = []
        for value in row {
            switch value {
            case .null: cells.append("NULL")
            case .integer(let n): cells.append("\(n)")
            case .double(let d): cells.append("\(d)")
            case .text(let s): cells.append(s)
            case .blob(let b): cells.append("<\(b.count) bytes>")
            }
        }
        out += cells.joined(separator: " | ") + "\n"
    }
    return out
}
