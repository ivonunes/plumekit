# CLI & configuration

`plumekit` is one binary that scaffolds, runs, migrates, builds and deploys your app. It also drives the Plume templating toolchain in-process. This page is the command and configuration reference.

## The `./plumekit` wrapper

Every scaffolded project includes a committed `./plumekit` wrapper script. It reads the PlumeKit version your project resolves to from `Package.resolved` (the SwiftPM lock file), downloads the matching CLI release from GitHub on first use, verifies its checksum, caches it and runs it.

Contributors and CI therefore need nothing installed beyond a Swift toolchain: run `./plumekit …` and you get the version your app builds against.

Two environment variables override the wrapper. `PLUMEKIT_BIN=/path/to/plumekit` runs a local build instead, and `PLUMEKIT_VERSION=x.y.z` pins a specific release.

## Commands

Most commands take an optional `[path]` naming the project directory; it defaults to the current directory.

| Command | What it does |
| --- | --- |
| `plumekit new <name>` | Scaffold a new app. |
| `plumekit serve [path]` | Run the app natively. |
| `plumekit dev [path]` | Serve, rebuilding on file changes. |
| `plumekit console [path]` | Interactive REPL against the app. |
| `plumekit migrate [path]` | Apply pending migrations. |
| `plumekit seed [name] [path]` | Run the app's seeders, or just one. |
| `plumekit routes [path]` | List the app's registered routes, one per line as `METHOD`, path and `file:line` of the registration, tab-separated. |
| `plumekit generate <kind> …` | Scaffold code or CI workflows (alias: `g`). |
| `plumekit test [path]` | Run the app's test suite. |
| `plumekit doctor` | Report the per-target toolchain state. |
| `plumekit mcp` | Run an MCP server (stdio) giving AI coding agents accurate PlumeKit APIs; see [MCP for AI agents](mcp.md). |
| `plumekit build [path]` | Build the deployable target(s). |
| `plumekit deploy [path]` | Migrate, seed, build and deploy. |
| `plumekit secret set <NAME> [path]` | Set a deploy secret (`secret list` lists them). |
| `plumekit token` | Open the pre-filled deploy-token creation page. |
| `plumekit login` | Store deploy credentials (`logout` forgets them). |
| `plumekit version` | Print the CLI version. |

The Plume templating commands (`compile`, `check`, `bundle`, `format`, `language-server`) are part of the same binary; see [Tooling](tooling/index.md).

### Creating an app

`plumekit new <name>` scaffolds a new app. At a TTY it asks a short series of questions (capabilities, build target, database driver, Dockerfile, CI); otherwise it takes the defaults. `--path <dir>` makes the new app depend on a local framework checkout instead of the released package.

### Running the app

`plumekit serve` builds and runs the native server, on `127.0.0.1:8080` unless you pass `--host` or `--port`. `plumekit dev` does the same but rebuilds on source, template and config changes: the old server keeps running until the new build succeeds, then swaps in, and open browser pages reload themselves on the swap.

`plumekit console` starts an interactive REPL against the app with the native bindings attached; type `GET /path` to exercise a route.

### Migrations and seeding

`plumekit migrate` applies pending migrations against the native database. `plumekit seed` runs the app's seeders; `plumekit seed Demo` runs just the one named. Both accept the same flags for targeting a Cloudflare D1:

| Flag | Meaning |
| --- | --- |
| `--local` / `--remote` | Target a Cloudflare D1 instead of the native database. |
| `--env <name>` | Target a [deploy environment](deploying.md#deploy-environments)'s D1; requires `--local` or `--remote`. |
| `--db <name>` | Name the D1 database explicitly. |
| `--yes`, `-y` | Skip wrangler's confirmation prompts. |
| `--rollback [N]` | Reverse the newest N migrations (default 1); `migrate` only. |
| `--status` | List each migration as applied or pending; `migrate` only. |

`--remote` goes over the Cloudflare API when a token is available (`CLOUDFLARE_API_TOKEN` or a stored `plumekit login`), and through wrangler otherwise; `--local` always uses wrangler, because the local D1 lives in its simulator state. `--rollback` and `--status` work against the native database only: D1 migrations are applied as forward-only SQL batches, so write a new migration to undo one. See [Migrations](migrations.md).

### Testing

`plumekit test` runs the app's test suite. Extra flags pass straight through to `swift test`:

```sh
plumekit test --filter PostTests
```

### Generating code

`plumekit generate <kind>` (alias `g`) scaffolds a resource, model, controller, migration, view, middleware, job, seeder, test, auth, notifications or CI:

```sh
plumekit generate resource Post title:string body:text published:bool  # model + controller + views + migration
plumekit generate auth                         # register/login/logout/forgot/reset (web + JSON)
plumekit generate model Post title:string
plumekit generate migration add_index
plumekit generate ci --provider github         # or gitlab | forgejo
```

Generators never overwrite a file, and each one prints how to wire what it creates. They run against the project root: from a subdirectory the CLI walks up to find it, or you point at it with `--path <dir>`.

A generator whose output needs a capability the app has off (`resource` and `model` need `database`; `auth` also needs `kv` and `secrets`) offers to enable it in `plumekit.toml`, or says exactly what to flip. `generate ci` writes a test-on-PR workflow and a deploy-on-push workflow (which runs `./plumekit deploy`), tailored to your default build target.

The full reference, including the `resource` scaffold and the `auth` flow, is in [Generators](generators.md).

### Building and deploying

`plumekit build` builds the target(s) declared in `[build]` in `plumekit.toml`, or the one you name with `--target cloudflare|aws|all`. `plumekit deploy` migrates, optionally seeds, builds and deploys. Both take `--env <name>` to work on a [deploy environment](deploying.md#deploy-environments). See [Deploying](deploying.md) for the whole flow.

### Secrets and credentials

`plumekit secret set NAME` sets a worker secret over the Cloudflare API. The value is read from a hidden prompt, or from stdin when piped, never from the command line. `plumekit secret list` lists the names. Both take `--env <name>` to target an environment's worker.

`plumekit login` stores a verified Cloudflare API token (and a default account) for deploys; `plumekit logout` forgets it. `plumekit token` opens the dashboard's create-token page pre-filled with the permissions deploys need. All three accept an optional provider argument and default to the app's default target; Cloudflare is the only provider with a credential store today (AWS uses its own credential chain).

### Checking the toolchain

`plumekit doctor` reports the state of each target's toolchain: Swift, the Embedded WebAssembly SDK, wasm-opt, Cloudflare auth, node, libpq, the aws CLI and docker.

## `plumekit.toml`

The project manifest declares your capabilities and per-target configuration. The build-tool plugin reads it on every `swift build` to generate the typed `Bindings` gate and the composition root; the CLI reads its `[build]` and `[deploy]` sections:

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
mailer   = false

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

Enabling a capability generates a typed, non-optional accessor on `request.bindings` (for example `request.bindings.database`). Switching a driver and rebuilding relinks a different adapter with no app-code change. See [Bindings & the capability model](bindings.md) and [Portability](portability.md).

## `.env`

`serve`, `dev`, `console`, `routes`, `migrate` and `seed` load a `.env` file from the project root into the environment (existing variables win), so `DATABASE_URL`, secrets and other config are picked up without hand-exporting:

```sh
# .env
DATABASE_URL=host=localhost port=5432 dbname=app
```
