# Hello — PlumeKit dogfood app

The example PlumeKit app, exercising the whole pipeline including async handlers,
KV, cache, the ORM, and channels. Depends on the framework by relative path
(`../..`).

Routes (in `Sources/App/App.swift`):

| Route             | Behaviour                                              |
| ----------------- | ----------------------------------------------------- |
| `GET /`           | `Hello from PlumeKit`                                  |
| `GET /hello/:name`| greeting with the path param                          |
| `GET /count`      | KV-backed visit counter (async `kv.get`/`kv.put`)     |
| `GET /kv/:key`    | read raw bytes from KV (404 if absent)                |
| `PUT /kv/:key`    | store the request body in KV                          |
| `GET /cache`      | a TTL'd counter through the cache binding             |
| `GET /page`       | a Plume-rendered HTML page (`Views/Views.plume`)  |
| `GET /orm`        | an `@Model` save→find round-trip                      |
| `GET /healthz`    | `{"status":"ok"}`                                      |

The `/page` view is authored in `Views/Views.plume` and compiled to
`Sources/App/Generated/Views.swift` by the Plume compiler embedded in `plumekit`
(no separate install) — see [docs/plume-views.md](../../docs/plume-views.md).

```sh
# Native (KV persisted under .plumekit/kv; shared with the console)
plumekit serve Fixtures/Hello
plumekit console Fixtures/Hello          # type `GET /count`
plumekit migrate Fixtures/Hello          # apply the app's migrations

# Cloudflare Wasm (KV via JSPI)
plumekit build --target cloudflare Fixtures/Hello
cd Fixtures/Hello/dist/cloudflare && npx wrangler dev
#   GET /count   -> count=1, 2, 3, …

# AWS Lambda (provided.al2 bootstrap + function.zip)
plumekit build --target aws Fixtures/Hello
#   Fixtures/Hello/dist/aws/{bootstrap, function.zip, README.md}
#   Local end-to-end run against LocalStack: ./support/aws-localstack.sh
```

`Sources/Server`, `Sources/Worker`, and `Sources/Lambda` are the thin native, Wasm,
and AWS Lambda entry points — the same `App` routes across all three runtimes.
`plumekit build --target aws` packages the Lambda target as a `provided.al2` custom
runtime. See [docs/aws.md](../../docs/aws.md).
