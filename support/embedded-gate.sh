#!/usr/bin/env bash
#
# embedded-gate.sh — the link-and-run gate for Plume's compiling back-end.
#
# Compiles Fixtures/EmbeddedGate/Views with `plumekit compile`, then builds the
# generated code + PlumeRuntime two ways and asserts byte-exact output:
#
#   1. NATIVE          host toolchain, run directly.
#   2. EMBEDDED-WASM   the Embedded-Swift Wasm SDK, LINKED to an executable and
#                      run under Node's WASI.
#
# A library-only build hides Embedded link-time failures (e.g. String == pulling
# in absent Unicode tables), so this gate deliberately links and runs the wasm.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO/Fixtures/EmbeddedGate"
SDK="${PLUME_WASM_SDK:-swift-6.3.2-RELEASE_wasm-embedded}"
GEN="$GATE/Sources/Gate/Generated"
EXPECTED="$GATE/expected.txt"

echo "==> Building the plumekit CLI"
swift build --package-path "$REPO" --product plumekit >/dev/null

echo "==> Compiling templates -> Swift (plumekit compile)"
rm -rf "$GEN"; mkdir -p "$GEN"
swift run --package-path "$REPO" plumekit compile "$GATE/Views" -o "$GEN"

fail() { echo "GATE FAILED: $1" >&2; exit 1; }

echo "==> [native] build + run"
swift build --package-path "$GATE" >/dev/null
NATIVE_BIN="$(swift build --package-path "$GATE" --show-bin-path)/Gate"
"$NATIVE_BIN" > "$GATE/.native.out"
cmp -s "$GATE/.native.out" "$EXPECTED" || { diff <(cat "$EXPECTED") "$GATE/.native.out" || true; fail "native bytes mismatch"; }
echo "    native bytes OK"

if ! command -v node >/dev/null 2>&1; then
    echo "==> [embedded] SKIPPED (node not found)"; exit 0
fi
if ! swift sdk list 2>/dev/null | grep -q "$SDK"; then
    echo "==> [embedded] SKIPPED (SDK '$SDK' not installed)"; exit 0
fi

echo "==> [embedded-wasm] build + LINK + run (node:wasi)"
swift build --package-path "$GATE" --swift-sdk "$SDK" >/dev/null
WASM="$(swift build --package-path "$GATE" --swift-sdk "$SDK" --show-bin-path)/Gate.wasm"
cat > "$GATE/run.mjs" <<'JS'
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
const wasi = new WASI({ version: 'preview1', args: ['gate'], env: {}, returnOnExit: true });
const module = await WebAssembly.compile(await readFile(process.argv[2]));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
const code = wasi.start(instance);
if (code !== 0) { process.stderr.write('exit ' + code + '\n'); process.exit(code); }
JS
# --experimental-wasi-unstable-preview1 is required by older LTS Node and accepted
# (as a no-op) by newer Node, so the gate runs across versions.
node --experimental-wasi-unstable-preview1 "$GATE/run.mjs" "$WASM" > "$GATE/.embedded.out"
cmp -s "$GATE/.embedded.out" "$EXPECTED" || { diff <(cat "$EXPECTED") "$GATE/.embedded.out" || true; fail "embedded bytes mismatch"; }
echo "    embedded-wasm bytes OK"

echo "GATE PASSED: native and Embedded-Wasm render identical, correct bytes."
