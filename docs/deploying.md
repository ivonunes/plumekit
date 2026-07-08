# Deploying

The same `buildApp()` deploys three ways: a Cloudflare Worker, an AWS Lambda or a
container running the native server, selected by your `[build]` target in
`plumekit.toml`. One command builds and ships it.

## `plumekit deploy`

```sh
plumekit deploy                 # the [build] default target
plumekit deploy --target aws    # a specific target
plumekit deploy --target all    # every target in [build] targets
```

`deploy` runs, in order: **migrate → seed → build → deploy**. Migrations and seeders
are controlled by `[deploy]` in `plumekit.toml` (`migrate = true`, `seed = false` by
default), and overridable per run:

```sh
plumekit deploy --skip-migrations     # don't migrate
plumekit deploy --seed                # also run seeders
plumekit deploy --skip-seed           # don't seed
```

What each target does:

- **cloudflare**: migrate the remote D1, build the Worker, `wrangler deploy`.
- **aws**: migrate the configured database, build the Lambda bundle, `aws lambda
  update-function-code`. See [Deploying to AWS Lambda](aws.md).
- **native**: migrate, then `docker build` the container image (push it to your
  registry / platform yourself).

## Cloudflare & `wrangler.toml`

`plumekit build --target cloudflare` emits a deployable bundle in `dist/cloudflare/`
(the `app.wasm` module, a dependency-free `worker.mjs` and `wrangler.toml`). It also
copies your `Public/` directory to `dist/cloudflare/public`, and the generated
`wrangler.toml` carries an `[assets]` block (`directory = "./public"`) so Cloudflare
serves a matching path (`/app.<hash>.css`, `/app.<hash>.js`, your images) directly;
every other request runs the Worker. See [Static files](#static-files-public).

Your `wrangler.toml` is **yours to own**. The first build writes one at the project
root from a template; after that, build reuses your copy, so custom domains,
logging/observability, `[vars]`, compatibility flags and extra bindings you add are
never overwritten. Commit it. (Only `worker.mjs`, the JSPI glue, is regenerated each
build.)

```sh
plumekit build --target cloudflare
# customise ./wrangler.toml (bindings, routes, domains, logging …), then:
cd dist/cloudflare && npx wrangler deploy    # or `plumekit deploy`
```

## Static files (`Public/`)

Scaffolded apps have a `Public/` directory, and your app references each asset by the
**same URL path on every target**; only *who* serves it changes:

- **native**: the server serves files under `Public/` directly (path-traversal-safe,
  `Content-Type` by extension, a `Cache-Control` header); a GET miss falls through to
  your routes.
- **cloudflare**: `Public/` → `dist/cloudflare/public`, served by the `[assets]`
  block in `wrangler.toml` (above).
- **aws**: `plumekit build --target aws` copies `Public/` → `dist/aws/public`. Upload
  it to S3 and front it with CloudFront (routing dynamic paths to the Lambda); the
  generated `dist/aws/README.md` has the exact `aws s3 sync` command and CloudFront
  setup. See [Deploying to AWS Lambda](aws.md#static-files-public).

The regenerated Plume bundle (`Public/app.*`) is gitignored; your own `Public/`
files are tracked. See [Portability](portability.md#static-files-public) for the whole
picture, and [`Storage.serve`](bindings.md#serving-stored-objects) for *runtime*
uploads (not static files).

## Containers (the native server)

Scaffolded apps include a multi-stage `Dockerfile` that builds the native `Server`
and runs it on `0.0.0.0:8080`. Deploy it anywhere that runs containers (Fly.io,
Render, ECS, a VPS, Kubernetes):

```sh
docker build -t bookmarks .
docker run -p 8080:8080 bookmarks
# or: plumekit deploy --target native
```

## CI

Generate CI that tests on pull requests and deploys on push to `main`:

```sh
plumekit generate ci --provider github     # or gitlab | forgejo
```

This writes a **test** workflow (`swift test` on PRs) and a **deploy** workflow
(`./plumekit deploy` on push to `main`, so migrations run on deploy), with the
toolchain set up for your default target and `${{ secrets.* }}` placeholders to fill
in. Because CI calls the committed `./plumekit` wrapper, it needs nothing installed
but a Swift toolchain.
