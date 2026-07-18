# CLI & configuration

`plumekit` is the single CLI that scaffolds, runs, migrates, builds and deploys your
app, and drives the Plume templating toolchain in-process. This page is the command
and configuration reference.

## The `./plumekit` wrapper

Every scaffolded project includes a committed `./plumekit` wrapper script. It reads
the PlumeKit version your project resolves to from `Package.resolved` (the SwiftPM
lock file), downloads the matching CLI release from
GitHub on first use, verifies its checksum, caches it and runs it. Contributors
and CI need nothing installed beyond a Swift toolchain: run `./plumekit …` and you
get the version your app builds against.

Overrides: `PLUMEKIT_BIN=/path/to/plumekit` (use a local build), `PLUMEKIT_VERSION=x.y.z`.

## Commands

| Command | What it does |
| --- | --- |
| `plumekit new <name>` | Scaffold a new app. Interactive at a TTY (capabilities, target, DB driver, Dockerfile, CI); use defaults otherwise. `--path <dir>` depends on a local framework checkout. |
| `plumekit serve [path]` | Run the app natively. `--host`, `--port`. |
| `plumekit dev [path]` | Serve, rebuilding and restarting on source/template changes. |
| `plumekit console [path]` | Interactive REPL against the app + native bindings; type `GET /path`. |
| `plumekit migrate [path]` | Apply migrations against the native DB. `--local` / `--remote` target a Cloudflare D1 (`--remote` over the Cloudflare API with `CLOUDFLARE_API_TOKEN`, wrangler otherwise). |
| `plumekit seed [path]` | Run the app's seeders (same `--local` / `--remote`). |
| `plumekit routes [path]` | List the app's registered routes. |
| `plumekit generate <kind> …` | Scaffold a resource, model, controller, migration, view, middleware, job, seeder, test, auth, notifications or CI. Alias: `g`. See [Generators](generators.md). |
| `plumekit test [path]` | Run the app's test suite. |
| `plumekit doctor` | Report the per-target toolchain state (Swift, wasm SDK, wasm-opt, Cloudflare auth, libpq, aws, docker). |
| `plumekit mcp` | Run an MCP server (stdio) giving AI coding agents accurate PlumeKit APIs; see [MCP for AI agents](mcp.md). |
| `plumekit build [path]` | Build the target(s) from `[build]` (or `--target cloudflare\|aws\|all`). |
| `plumekit deploy [path]` | Migrate, (seed,) build and deploy; see [Deploying](deploying.md). |
| `plumekit secret set <NAME> [path]` | Set a worker secret over the Cloudflare API (value via hidden prompt or stdin). `secret list` lists them. |
| `plumekit token` | Open the dashboard's create-token page pre-filled with the permissions deploys need. |
| `plumekit login` | Store a verified Cloudflare API token (and a default account) for deploys. `logout` forgets it. |

The Plume templating commands (`compile`, `check`, `bundle`, `format`,
`language-server`) are part of the same binary; see [Tooling](tooling/index.md).

### `plumekit generate`

```sh
plumekit generate resource Post title:string body:text published:bool  # model + controller + views + migration
plumekit generate auth                         # register/login/logout/forgot/reset (web + JSON)
plumekit generate model Post title:string
plumekit generate migration add_index
plumekit generate ci --provider github         # or gitlab | forgejo
```

Kinds: `resource`, `model`, `controller`, `migration`, `view`, `middleware`, `job`,
`seeder`, `test`, `auth`, `notifications`, `ci`. Generators never overwrite a file and print how to wire what
they create. `generate ci` writes a test-on-PR workflow and a deploy-on-push workflow
(which runs `./plumekit deploy`), tailored to your default build target. The full
reference, including the `resource` scaffold and the `auth` flow, is in
**[Generators](generators.md)**.

## `plumekit.toml`

The project manifest declares your capabilities and per-target configuration. The
build-tool plugin reads it on every `swift build` to generate the typed `Bindings`
gate and the composition root; the CLI reads its `[build]` / `[deploy]` sections.

```toml
# Which capabilities the app uses. Using one not declared here is a compile error
# (there's no accessor for it on request.bindings).
[capabilities]
kv       = true
database = true
storage  = false
cache    = false
queue    = false
http     = false
secrets  = false

# `plumekit build`/`deploy` with no --target use `default`; `--target all` covers
# every entry in `targets`. `--target <name>` overrides.
[build]
default = "cloudflare"
targets = ["cloudflare", "aws"]
# out   = "dist"          # bundle output directory (default: dist)

# What `plumekit deploy` runs before shipping. Override per run with
# --skip-migrations / --seed / --skip-seed.
[deploy]
migrate = true
seed    = false

# Native drivers (plumekit serve / dev).
[targets.native]
database = "sqlite"       # sqlite | postgres
storage  = "filesystem"   # filesystem | memory | s3

# Cloudflare adapters; bindings are configured in wrangler.toml.
[targets.cloudflare]
database = "d1"
storage  = "r2"

# AWS Lambda adapters (see docs/aws.md).
[targets.aws]
database = "postgres"
storage  = "s3"
cache    = "dynamodb"
kv       = "dynamodb"
queue    = "sqs"
secrets  = "ssm"
```

Enabling a capability generates a typed, non-optional accessor on `request.bindings`
(e.g. `request.bindings.database`). Switching a driver and rebuilding relinks a
different adapter with no app-code change; see [Bindings & drivers](bindings.md) and
[Portability](portability.md).

## `.env`

`serve`, `dev`, `console`, `migrate` and `seed` load a `.env` file from the project
root into the environment (existing variables win), so `DATABASE_URL`, secrets and
other config are picked up without hand-exporting:

```sh
# .env
DATABASE_URL=host=localhost port=5432 dbname=app
```
