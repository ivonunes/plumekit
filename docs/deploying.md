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

- **cloudflare**: migrate the remote D1, build the Worker, deploy. Everything
  (D1, module upload, assets, durable-object migrations, cron schedules, queue
  consumers, custom domains) goes over the Cloudflare API — no wrangler or Node.
  Auth comes from `CLOUDFLARE_API_TOKEN`, the token stored by `plumekit login`,
  or an active `wrangler login` session (reused while valid).
- **aws**: migrate the configured database, build the Lambda bundle, `aws lambda
  update-function-code`. See [Deploying to AWS Lambda](aws.md).
- **native**: migrate, then `docker build` the container image (push it to your
  registry / platform yourself).

## Cloudflare configuration

Everything Cloudflare-specific lives in plumekit.toml's `[targets.cloudflare]`:
the account, compatibility date/flags, custom `domains`, `crons`, `[vars]` (as
`[targets.cloudflare.vars]`), resource-name overrides (`database_name`,
`queue_name`, `bucket_name`) and the pinned resource ids. `plumekit build
--target cloudflare` emits a deployable bundle in `dist/cloudflare/` — the
`app.wasm` module, a dependency-free `worker.mjs`, your `Public/` directory as
`./public` (served by the `[assets]` block; see
[Static files](#static-files-public)) and a **generated** `wrangler.toml`, so
`wrangler dev`/`wrangler tail` and a manual `npx wrangler deploy` keep working
against the bundle. Settings plumekit doesn't model go in a root
`wrangler.extra.toml`, appended to the generated file verbatim. (Projects with a
user-owned root `wrangler.toml` from earlier versions are migrated automatically:
its values are absorbed into plumekit.toml and the file is renamed to
`wrangler.toml.bak`.)

The first deploy **provisions what the manifest declares**: the D1 database, KV
namespaces, R2 bucket and queue are looked up by name and created when missing,
and fresh ids are pinned back into plumekit.toml. Ids are a pin, not a
requirement: in CI the writeback is discarded and resolution by name keeps
working, so nothing needs to commit from CI. Existing resources are adopted,
never recreated; nothing is ever deleted or renamed. Secrets are the one manual
step: `plumekit secret set NAME` after the first deploy.

```sh
plumekit build --target cloudflare
plumekit deploy    # or `cd dist/cloudflare && npx wrangler deploy`
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
