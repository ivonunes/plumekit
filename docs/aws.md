# Deploying to AWS Lambda

AWS Lambda is a first-class PlumeKit runtime, alongside the native SwiftNIO server
and the Cloudflare Wasm Worker. The **same `buildApp()`** runs on all three: you
change `plumekit.toml` (and the deploy config) and rebuild. No app-code change, and
no `if platform == …` branch. On AWS your app runs as a `provided.al2` custom
runtime, fronted by API Gateway, with every host capability supplied by an AWS
service behind the existing capability protocols.

This page covers the AWS adapters, the `[targets.aws]` manifest profile, the environment it
reads, packaging with `plumekit build --target aws`, deploying to Lambda + API
Gateway, and local testing against LocalStack.

## Three runtimes, one core

| Runtime            | Adapter module | How you ship it                     |
| ------------------ | -------------- | ----------------------------------- |
| Native (SwiftNIO)  | `PlumeServer`  | `plumekit serve` (long-lived process) |
| Cloudflare Worker  | `PlumeWorker`  | `plumekit build --target cloudflare` (Wasm) |
| AWS Lambda         | `PlumeAWS`     | `plumekit build --target aws` (`provided.al2`) |

App code names a capability (`request.bindings.database`, `request.bindings.storage`,
…), never a platform type. The manifest selects which adapters are linked; the
generated composition root wires them into the `Context` your handlers receive.

## Capabilities → AWS adapters

Each neutral capability protocol has an AWS-service adapter. They live in `PlumeAWS`
(SigV4 signing + the service clients and the Lambda runtime), with `PlumeS3` for
object storage and `PlumePostgres` for the database:

| Capability      | Protocol         | AWS adapter                                          |
| --------------- | ---------------- | --------------------------------------------------- |
| Object storage  | `StorageDriver`  | **S3**                                               |
| Queue           | `MessageQueue`   | **SQS**                                              |
| Secrets         | `SecretStore`    | **SSM Parameter Store**                              |
| KV              | `KV`             | **DynamoDB**                                         |
| Cache           | `Cache`          | **DynamoDB** (TTL via the table's TTL attribute)     |
| Mailer          | `Mailer`         | **SES**                                              |
| HTTP / fetch    | `HTTPClient`     | **URLSession**                                       |
| SQL             | `SQLDatabase`    | **RDS Postgres** (via `PlumePostgres`)               |
| Channels        | `Channel`        | **API Gateway WebSockets** (DynamoDB state + `postToConnection` fan-out) |

Cache reuses the DynamoDB adapter but relies on the table's TTL attribute so expired
entries are swept automatically. The contract is the same best-effort one as on every
other target: a miss means "recompute", never "gone for good".

Real-time channels drive a third structurally-different runtime unchanged. The
`Channel` protocol's synchronous-handler-over-a-pre-loaded-store shape (built for the
Cloudflare Durable Object) maps cleanly onto API Gateway WebSockets: connection and
per-channel state live in DynamoDB, and the adapter fans messages out with the API
Gateway Management API's `postToConnection`. See [Channels](channels.md).

## The `[targets.aws]` profile

The AWS adapter set is selected by an `[targets.aws]` profile in `plumekit.toml`, exactly like
the `[targets.native]` and `[targets.cloudflare]` profiles. The **PlumeKitCodegen** build-tool plugin
generates the composition root from it (as `Composition.awsContext()`) on every
`swift build`, the direct analogue of the native `Composition.nativeContext()`:

```toml
[targets.aws]
database = "postgres"   # RDS Postgres (SQLDatabase)
storage  = "s3"         # S3
queue    = "sqs"        # SQS
secrets  = "ssm"        # SSM Parameter Store
channel  = "apigateway" # API Gateway WebSockets + DynamoDB
```

The `[capabilities]` table (shared by every target) still gates which typed
`request.bindings` accessors exist. Declaring a capability you don't wire, or using
one you didn't declare, is a **compile error**, on AWS the same as everywhere else.

## Configuration (environment)

Config is runtime, read from the process environment (which on Lambda is the function
configuration), never compiled in. The key variables:

| Variable                  | Purpose                                                          |
| ------------------------- | --------------------------------------------------------------- |
| `AWS_REGION`              | Region for every service client.                                |
| `AWS_ACCESS_KEY_ID`       | SigV4 credentials (or the Lambda execution role's injected creds). |
| `AWS_SECRET_ACCESS_KEY`   | SigV4 credentials.                                              |
| `AWS_ENDPOINT_URL`        | Overrides **all** service endpoints; set to `http://localhost:4566` for LocalStack. |
| `DATABASE_URL`            | RDS Postgres connection string.                                 |
| `S3_BUCKET`               | Object-storage bucket.                                          |
| `KV_TABLE`                | DynamoDB table backing the KV capability.                       |
| `CACHE_TABLE`             | DynamoDB table backing the cache (with a TTL attribute).        |
| `SQS_URL`                 | Queue URL for the SQS producer.                                 |
| `CHANNEL_TABLE`           | DynamoDB table holding channel connections + state.             |
| `CHANNEL_MGMT_ENDPOINT`   | API Gateway Management API endpoint used for `postToConnection`. |

Because `AWS_ENDPOINT_URL` overrides every service endpoint at once, the same binary
targets real AWS or a local LocalStack simply by setting (or unsetting) that one
variable.

## Packaging: `plumekit build --target aws`

```sh
plumekit build --target aws            # from the app directory
plumekit build --target aws Fixtures/Hello
```

This produces `dist/aws/`:

```
dist/aws/
├── bootstrap        # the entrypoint binary (provided.al2 expects this name)
├── function.zip     # bootstrap zipped, ready to upload as the function code
├── public/          # your Public/ static files, copied for S3 + CloudFront
└── README.md        # the generated deploy notes
```

Lambda's `provided.al2` custom runtime looks for an executable named **`bootstrap`**.
That binary is the app's `Lambda` entry point: `LambdaAdapter.run` polls the Lambda
Runtime API and maps API Gateway proxy events ↔ PlumeKit `Request`/`Response`. Both
API Gateway flavours are handled: HTTP API **v2** (payload format 2.0) and REST API
**v1** (payload format 1.0).

### Linux SDK for a real deploy

Lambda runs Linux, so a real deploy needs a **Linux** binary. Point
`PLUMEKIT_LINUX_SDK` at a static Linux Swift SDK (install one from
[swift.org](https://www.swift.org/download/), or use the static-Linux SDK) and
rebuild:

```sh
export PLUMEKIT_LINUX_SDK=<swift-linux-sdk-id>
plumekit build --target aws
```

Without `PLUMEKIT_LINUX_SDK` the CLI builds with the **host** toolchain. That is fine
for driving the Lambda locally as a plain process (e.g. against LocalStack), but the
resulting `bootstrap` will not run on Lambda itself.

## Deploying

1. **Provision the services** the `[targets.aws]` profile references: an S3 bucket, the SQS
   queue, SSM parameters for your secrets, the DynamoDB tables (KV, cache with a TTL
   attribute, and channel state), an RDS Postgres instance, and the SES identity.
2. **Create the function** on the `provided.al2` runtime with `function.zip` as the
   code and `bootstrap` as the handler. Set the environment variables from the table
   above; the execution role supplies the AWS credentials.
3. **Front it with API Gateway.** An HTTP API (v2) or REST API (v1) proxies all routes
   to the function. For real-time channels, add a WebSocket API and give the function
   `execute-api:ManageConnections` so `postToConnection` can fan out; point
   `CHANNEL_MGMT_ENDPOINT` at that API's management endpoint.
4. **Run migrations** against RDS Postgres with `plumekit migrate` (migrations are
   native-only; they run from the CLI/a build step, never inside the function). The
   dialect travels with the handle, so the same migrations that run on SQLite/D1 apply
   `SERIAL`-style DDL on Postgres. See [Migrations](migrations.md).

## Static files (`Public/`)

Your app's `Public/` directory (styles, images, and the content-hashed Plume bundle
`app.*`) is copied to `dist/aws/public` by the build. On AWS, static files are not
served by the Lambda: you **upload them to S3 and front them with CloudFront**, which
routes the asset paths (`/app.<hash>.css`, `/app.<hash>.js`, your own files) to S3 and
every other path to the API Gateway/Lambda. The generated `dist/aws/README.md` has the
concrete `aws s3 sync` command and the CloudFront origin/behavior setup; follow it
there rather than by hand.

Because your app references each asset by the same URL path on every target, nothing
in the app changes; only *who* serves the path does. See
[Portability](portability.md#static-files-public). For *runtime* uploads (avatars,
exports) served from S3 rather than static files, use
[`Storage.serve`](bindings.md#serving-stored-objects).

## Local testing with LocalStack

You can exercise the whole AWS runtime locally with
[LocalStack](https://www.localstack.io/). The one switch is `AWS_ENDPOINT_URL`: set it
to `http://localhost:4566` and every service client talks to LocalStack instead of
real AWS.

The framework ships **`support/aws-localstack.sh`**, which boots LocalStack and
Postgres, provisions the resources (bucket, queue, SSM parameters, DynamoDB tables),
builds the Hello app for AWS, and drives its Lambda against the local endpoints:

```sh
./support/aws-localstack.sh
```

S3, SQS, SSM, and DynamoDB run on LocalStack, so storage, queue, secrets, KV, cache,
and the API Gateway channel store are all exercised locally against the same adapters
you deploy.

## See also

- [Deploying](deploying.md): `plumekit deploy`, CI, and containers; AWS is one of its
  three targets.
- [Portability](portability.md): how the one-core/many-adapters invariant holds across
  native, Cloudflare, and AWS.
- [Bindings & drivers](bindings.md): the capability protocols and the per-target
  adapter table (native, Cloudflare, AWS).
- [Channels](channels.md): the platform-neutral real-time protocol driving all three
  runtimes.
- [Migrations](migrations.md): hand-authored migrations applied against RDS Postgres.
