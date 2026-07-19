import PlumeCore
import PlumeORM
import _Concurrency

// The example's versioned API surface — /api/v1, bearer-token only, structured
// errors, pagination, allow-list serialization. SEPARATE from the web routes; the
// negotiated web endpoints are unchanged.

extension Post: APIRepresentable {
    // EXPLICIT allow-list: id, title, views. `published` and the timestamps are NOT
    // exposed — the API representation is declared, never a raw table dump.
    public func apiJSON() -> JSONValue {
        .object([
            ("id", .int(Int64(id))),
            ("title", .string(title)),
            ("views", .int(Int64(views))),
        ])
    }
}

func registerAPIRoutes(_ app: Application) {
    // API middleware — applies only to /api/ paths (its own stack): require a bearer
    // token (no cookie/CSRF here) and rate-limit. On by default for the API surface.
    app.use(requireAPIToken(prefix: "/api/"))
    app.use(rateLimit(prefix: "/api/", limit: 100, windowSeconds: 60, now: authNowSeconds))

    // GET /api/v1/posts?limit=&offset= — paginated, allow-list serialized.
    app.get("/api/v1/posts") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let limit = min(Int(request.queryParams["limit"] ?? "") ?? 20, 100)
        let offset = Int(request.queryParams["offset"] ?? "") ?? 0
        let page = try await Post.query().order(by: Post.id).paginate(limit: limit, offset: offset, in: db)
        return .json(paginatedJSON(page.items.map { $0.apiJSON() },
                                   limit: page.limit, offset: page.offset, hasMore: page.hasMore))
    }

    // POST /api/v1/posts — create; validation failures return the structured envelope.
    app.post("/api/v1/posts") { request in
        let db = request.bindings.database
        try await Post.createTable(in: db)
        let post = Post(title: authField(request, "title") ?? "", views: 0, published: false)
        let errors = try await post.save(in: db)
        if !errors.isEmpty {
            return APIError(status: 422, code: "validation_failed", message: "the request is invalid",
                            fields: errors.map { (field: $0.field, message: $0.message) }).response()
        }
        return .json(post.apiJSON(), status: 201)
    }
}
