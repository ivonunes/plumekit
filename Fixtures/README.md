# Fixtures

These are the CI **verification apps** — real PlumeKit apps the quality gates build
and run on every change, not tutorials:

- **Hello** — the full integration app. The embedded link gate
  (`support/embedded-check.sh`) builds its Worker for Wasm, the conformance suite
  runs its native Server, CI builds it with `plumekit build --target cloudflare`,
  and the LocalStack workflow drives its AWS front-end.
- **EmbeddedGate** — the render-gate fixture (`support/embedded-gate.sh`): proves a
  Plume view renders **byte-identical** natively and in the Embedded-Wasm guest.

Looking for a starting point for your own app? Use `plumekit new` — the scaffold is
the real "hello world", and the [tutorial](../docs/start/tutorial.md) walks it end
to end.
