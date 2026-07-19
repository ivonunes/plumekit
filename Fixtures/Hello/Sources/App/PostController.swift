import PlumeCore
import PlumeORM
import PlumeRuntime

// A RESTful resource controller over the Post @Model — the same CRUD code runs on
// native SQLite and Cloudflare D1. Wired with `app.resources("/api/posts", …)`.
// (Responses content-negotiate: JSON when requested, plain text otherwise.)
struct PostController: Controller {
    // Content-negotiated: `Accept: application/json` → JSON, else plain text.
    func index(_ request: Request) async throws -> Response {
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let posts = try await Post.query().order(by: Post.id, .ascending).all(in: db)
        if request.wantsJSON { return .json(jsonArray(posts)) }
        var body = "posts (\(posts.count)):"
        for post in posts { body += "\n#\(post.id) \(post.title)" }
        return .text(body)
    }

    func show(_ request: Request) async throws -> Response {
        let db = request.bindings.database
        guard let id = Int(request.parameters["id"] ?? "") else { return .text("bad id", status: 400) }
        guard let post = try await Post.find(id, in: db) else { return .text("not found", status: 404) }
        if request.wantsJSON { return .json(post.jsonObject()) }
        return .text("#\(post.id) \(post.title) views=\(post.views)")
    }

    // One action, three negotiated representations. Success → redirect
    // (no-JS, POST-redirect-GET) / stream (JS) / JSON (API). Validation failure →
    // re-rendered form fragment with errors + preserved input (web) / stream (JS) /
    // structured errors (API). Errors negotiate too — that's the point.
    func create(_ request: Request) async throws -> Response {
        let db = request.bindings.database
        try await Post.createTable(in: db)

        let post: Post
        if request.hasJSONBody, let json = request.json() {
            post = Post.fromJSON(json)                       // API JSON body
        } else {
            let input = request.decode(PostForm.self)        // typed form decode
            post = Post(title: input.title, views: input.views, published: false)
        }

        let errors = try await post.save(in: db)
        if !errors.isEmpty {
            if request.wantsJSON { return .json(errorsJSON(errors), status: 422) }
            let form = renderPostForm(title: post.title, views: post.views, errors: errors)
            if request.wantsStream {
                var envelope = StreamEnvelope()
                envelope.add(.replace, target: "post-form", fragment: form.bytes)
                return .stream(envelope, status: 422)
            }
            return .view(fullPage(form), status: 422)        // no-JS: full page, input preserved
        }

        if request.wantsJSON { return .json(post.jsonObject(), status: 201) }
        if request.wantsStream {
            var envelope = StreamEnvelope()
            envelope.add(.prepend, target: "post-list") { card in
                card.literal("<li>#"); card.text(post.id); card.literal(" "); card.text(post.title); card.literal("</li>")
            }
            return .stream(envelope)                          // JS: targeted update
        }
        return .redirect(to: "/posts/new")                    // no-JS: POST-redirect-GET
    }

    func update(_ request: Request) async throws -> Response {
        let db = request.bindings.database
        guard let id = Int(request.parameters["id"] ?? "") else { return .text("bad id", status: 400) }
        guard let post = try await Post.find(id, in: db) else { return .text("not found", status: 404) }
        if let title = request.form["title"] { post.title = title }
        if let views = request.form.int("views") { post.views = views }
        let errors = try await post.save(in: db)
        if !errors.isEmpty { return invalid(errors) }
        return .text("updated #\(post.id)")
    }

    func destroy(_ request: Request) async throws -> Response {
        let db = request.bindings.database
        guard let id = Int(request.parameters["id"] ?? "") else { return .text("bad id", status: 400) }
        guard let post = try await Post.find(id, in: db) else { return .text("not found", status: 404) }
        try await post.delete(in: db)
        return .text("deleted #\(id)")
    }

    private func invalid(_ errors: [ValidationError]) -> Response {
        var body = "422 invalid:"
        for error in errors { body += "\n" + error.field + ": " + error.message }
        return .text(body, status: 422)
    }

    private func errorsJSON(_ errors: [ValidationError]) -> JSONValue {
        .object([("errors", .array(errors.map {
            .object([("field", .string($0.field)), ("message", .string($0.message))])
        }))])
    }
}
