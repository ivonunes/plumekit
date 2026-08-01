# API surface

Content negotiation already lets a web endpoint answer HTML or JSON, but a real API is more than a JSON response: it is a versioned contract with its own namespace, structured errors, pagination, rate limiting and explicit serialisation. PlumeKit's API surface is a separate, opt-in layer that provides exactly that; existing negotiated endpoints are unchanged. It is built on token auth and works the same on every target.

## Versioning and token auth

Mount routes under `/api/v1` and add the API middleware, scoped to `/api/` by path prefix. The API surface runs its own stack, with no cookies and no CSRF:

```swift
app.use(requireAPIToken(prefix: "/api/"))                              // bearer ONLY → 401 envelope
app.use(rateLimit(prefix: "/api/", limit: 100, windowSeconds: 60, now: nowSeconds))
app.get("/api/v1/posts") { ... }
```

`requireAPIToken` accepts only a bearer token, which the identity middleware resolves; cookie auth is rejected on the API surface. Per-route authorisation uses the same policies as the rest of the app (`request.authorize(...)`).

Treat a version as additive-safe: new fields and endpoints can land within it. A breaking change is a new version (`/api/v2`).

See [Auth](auth.md) for tokens, sessions and policies.

## Structured error envelope

An API client needs errors it can parse, so the envelope is machine-readable, never HTML:

```json
{"error":{"code":"validation_failed","message":"the request is invalid",
          "fields":[{"field":"title","message":"can't be blank"}]}}
```

`APIError(status:code:message:fields:)` builds it. Validation failures map to `fields`, and 401 (`unauthorized`), 422 (`validation_failed`) and 429 (`rate_limited`) all share the shape.

## Pagination

`Query.paginate(limit:offset:)` on the query builder returns a `Page`; it fetches `limit+1` rows to compute `hasMore` without a second query. `paginatedJSON` wraps the allow-list-serialised items and the metadata in a consistent envelope:

```json
{"data":[{"id":1,"title":"First","views":0}],
 "pagination":{"limit":20,"offset":0,"hasMore":true}}
```

See [The ORM](orm.md#pagination) for the full pagination API.

## Rate limiting

The `rateLimit` middleware counts requests in a KV-backed fixed window, per principal per window, and returns the structured **429** past the limit. Add it alongside `requireAPIToken` when you mount the API group, as shown above. It is platform-neutral: swap the counter by replacing the middleware.

## Serialisation allow-list

A model's JSON is an explicit allow-list it declares via `APIRepresentable.apiJSON()`, never "encode the whole model". The example `Post` exposes `id`, `title` and `views` only; `published` and the timestamps never appear in API output. A column you don't list cannot leak.

## Resource transformers

The same explicit-shape discipline is available as `Response` sugar. Conform a model to `JSONRepresentable` and return it directly:

```swift
extension Post: JSONRepresentable {
    var jsonValue: JSONValue {
        .object([("id", .int(Int64(id))), ("title", .string(title))])
    }
}

return .json(post)     // one resource
return .json(posts)    // an array of them
return .json(page)     // a Page: items + pagination metadata
```

`jsonValue` is code, not a derivation from stored properties, so the API contract never grows a column you didn't mean to expose. `.json(page)` wraps a `Page` (from `Query.paginate`) in the standard paginated shape with its `limit`, `offset` and `hasMore` metadata.

## Signed URLs

Sometimes a link must authenticate itself: an unsubscribe link, a file download, an invite. These routes work without a session because the URL carries its own signature:

```swift
// Issue (e.g. into an email); appends `sig` (and `sig_exp` when an expiry is given):
let url = SignedURL.sign("/unsubscribe?user=42", key: key,
                         expiresAt: Int64(nowSeconds + 86_400))

// Verify in the handler:
guard SignedURL.verify(request, key: key, nowEpochSeconds: now) else {
    return .status(403)
}
```

The signature is HMAC-SHA256 over the path and query, compared in constant time. Tampering with the path, the parameters or the expiry fails verification. `expiresAt` (epoch seconds) is optional; without it the link doesn't expire.
