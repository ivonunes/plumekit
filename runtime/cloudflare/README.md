# runtime/cloudflare

The Cloudflare Workers adapter's host side. `plumekit build --target cloudflare`
emits a bundle from these into `dist/cloudflare/`:

| File            | Role                                                                   |
| --------------- | ---------------------------------------------------------------------- |
| `worker.mjs`    | Module-worker entry: instantiates the Wasm module and marshals bytes.  |
| `wrangler.toml` | Worker config (`wrangler.toml.template` here, with `__NAME__` filled). |
| `app.wasm`      | The compiled Embedded-Swift module (added at build), size-optimized and debug-stripped with `wasm-opt -Oz --strip-debug` (override the arguments with `PLUMEKIT_WASM_OPT_ARGS`). |

`worker.mjs` is the canonical source; `plumekit build` reads it (and the wrangler
template) straight from this directory.

## How the glue works

1. Import the `.wasm` (Wrangler hands back a `WebAssembly.Module`) and
   `new WebAssembly.Instance(...)` it once, calling `_initialize()`.
2. WASI surface is minimal: `random_get` (Web Crypto) + the Swift concurrency
   runtime's stdio, which is auto-stubbed from the module's own import list — so
   instantiation never fails on a missing import. **No npm dependencies, no WASI
   shim library.**
3. Per request: encode the `Request` into PlumeKit's compact wire format, write it
   into guest memory via `plumekit_alloc`, call `plumekit_handle(ctx, …)`, read the
   `[u32 ptr][u32 len]` response descriptor back, then `plumekit_free`.

## Async host bindings

The guest can `await` host APIs (KV) via **JSPI**:

- Async host imports (`host_kv_get`/`host_kv_put`) are wrapped with
  `WebAssembly.Suspending`; `plumekit_handle` is wrapped with
  `WebAssembly.promising`. Calling a host import suspends the whole wasm stack
  until the JS promise resolves, then resumes.
- `host_log` → `console.log`. These are custom **`env`** imports, not WASI.
- A `ctx` id passed to `plumekit_handle` routes host calls to the in-flight
  request's bindings via a context table — `env` is never globally cached.
- One handler runs at a time per isolate (a documented v1 simplification).

The wire format mirrors `Sources/PlumeKitWorker/WireFormat.swift`; the full design
and Embedded-Swift findings are in `docs/async-bridge.md`.

## Deploy

```
cd dist/cloudflare
wrangler dev                 # local workerd
wrangler deploy --dry-run    # validate the bundle without credentials
wrangler deploy              # ship it (needs a Cloudflare account / login)
```
