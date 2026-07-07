# API surface

A separate, opt-in surface for building a real API as a versioned contract. Content
negotiation already lets web endpoints answer HTML or JSON; the API surface is
different: a namespace with its own middleware, structured errors, pagination, rate
limiting, and allow-list serialization. Apps opt in; existing negotiated endpoints
are unchanged. Built on token auth. Works the same on every target.

## Versioning + token auth

Mount routes under `/api/v1` and add the API middleware, scoped to `/api/` by path
prefix (its own stack, no cookie/CSRF):

```swift
app.use(requireAPIToken(prefix: "/api/"))                              // bearer ONLY → 401 envelope
app.use(rateLimit(prefix: "/api/", limit: 100, windowSeconds: 60, now: nowSeconds))
app.get("/api/v1/posts") { ... }
```

`requireAPIToken` accepts only a bearer token (the identity middleware resolves
it); cookie auth is rejected on the API surface. Per-route authorization uses the
auth policies (`request.authorize(...)`). Versioning is additive-safe; a breaking
change is a new version (`/api/v2`).

## Structured error envelope

Machine-readable, never HTML:

```json
{"error":{"code":"validation_failed","message":"the request is invalid",
          "fields":[{"field":"title","message":"can't be blank"}]}}
```

`APIError(status:code:message:fields:)` builds it.
Validation failures map to `fields`. 401 (`unauthorized`), 422
(`validation_failed`), 429 (`rate_limited`) all share the shape.

## Pagination

`Query.paginate(limit:offset:)` over the query builder returns a `Page` (it fetches
`limit+1` to compute `hasMore` without a second query); `paginatedJSON` wraps the
allow-list-serialized items + metadata:

```json
{"data":[{"id":1,"title":"First","views":0}],
 "pagination":{"limit":20,"offset":0,"hasMore":true}}
```

## Rate limiting

`rateLimit` middleware over a KV-backed fixed-window counter (per principal, per
window); a structured **429** past the limit. Platform-neutral: swap the counter by
replacing the middleware. On by default for the API group.

## Serialization allow-list

A model's JSON is an explicit allow-list it declares via `APIRepresentable.apiJSON()`,
never "encode the whole model". The example `Post` exposes `id`, `title`, `views`
only; `published` and the timestamps never appear in API output. A column you don't
list cannot leak.

## Resource transformers

The same explicit-shape discipline, as `Response` sugar: conform a model to
`JSONRepresentable` and return it directly:

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

`jsonValue` is code, not a derivation from stored properties, so the API contract
never grows a column you didn't mean to expose. `.json(page)` wraps a `Page` (from
`Query.paginate`) in the standard paginated shape with its `limit`/`offset`/
`hasMore` metadata.

## Signed URLs

Links that authenticate themselves (unsubscribe links, file downloads, invites),
for routes that must work without a session:

```swift
// Issue (e.g. into an email); appends `sig` (and `sig_exp` when an expiry is given):
let url = SignedURL.sign("/unsubscribe?user=42", key: key,
                         expiresAt: Int64(nowSeconds + 86_400))

// Verify in the handler:
guard SignedURL.verify(request, key: key, nowEpochSeconds: now) else {
    return .status(403)
}
```

HMAC-SHA256 over the path + query, compared in constant time. Tampering with the
path, the parameters, or the expiry fails verification. `expiresAt` (epoch seconds)
is optional; without it the link doesn't expire.
