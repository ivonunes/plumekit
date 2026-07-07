#!/usr/bin/env bash
#
# Proves the portable core stays Embedded-Swift-clean. Two levels:
#
#   1. COMPILE the library targets (PlumeKit core + PlumeWorker glue) for
#      embedded-wasm.
#   2. LINK an embedded executable that exercises the async + KV paths.
#
# Level 2 matters: a library target only *compiles*; some Embedded violations
# (e.g. Unicode-table String comparison, the async runtime)
# only surface when an executable is *linked*. The example's `Worker` product is
# that executable — it drives the cooperative executor, the JSPI host imports,
# and the KV bridge, so linking it for wasm is the real gate.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SDK="$(swift sdk list 2>/dev/null | grep -E '_wasm-embedded$' | head -1 || true)"
if [ -z "${SDK}" ]; then
  echo "error: no Embedded-Swift WebAssembly SDK installed." >&2
  echo "Install one per https://www.swift.org/documentation/articles/wasm-getting-started.html" >&2
  exit 1
fi

echo "==> Embedded-clean check using SDK: ${SDK}"

# Embedded Swift requires whole-module compilation; a direct `--target` build
# otherwise uses batch mode (which mis-resolves cross-file types). The real Worker
# build (PlumeKit as a dependency, step 3 below) is WMO already, so match it here.
echo "--> [compile] target PlumeCore (portable core) for embedded wasm"
swift build --swift-sdk "${SDK}" --target PlumeCore -c release -Xswiftc -wmo

echo "--> [compile] target PlumeORM (@Model + factories) for embedded wasm"
swift build --swift-sdk "${SDK}" --target PlumeORM -c release -Xswiftc -wmo

echo "--> [compile] target 'PlumeWorker' (wasm glue) for embedded wasm"
swift build --swift-sdk "${SDK}" --target PlumeWorker -c release -Xswiftc -wmo

echo "--> [LINK] example 'Worker' executable for embedded wasm (async + KV paths)"
swift build --package-path "${ROOT}/Fixtures/Hello" \
  --swift-sdk "${SDK}" -c release --product Worker \
  -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor

WASM="${ROOT}/Fixtures/Hello/.build/wasm32-unknown-wasip1/release/Worker.wasm"
if [ ! -f "${WASM}" ]; then
  echo "error: expected linked wasm not found at ${WASM}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Native String == (and hasPrefix / hasSuffix / lowercased / split / Dictionary<String,_>)
# in the guest. These reference Swift's Unicode data tables; the fixture links them via
# `.linkedLibrary("swiftUnicodeDataTables")` (the same mechanism PlumeWorker uses), so
# they LINK and RUN with full Unicode semantics. This is ALSO the toolchain-drift guard:
# a Swift bump that renames the lib or changes the required symbols makes the fixture fail
# to link and fails loudly right here.
# ---------------------------------------------------------------------------
echo "--> [String ==] link + run the Unicode-tables fixture"
STRTEST="${ROOT}/Fixtures/StringEquality"
swift build --package-path "${STRTEST}" --swift-sdk "${SDK}" -c release
SEQ_WASM="${STRTEST}/.build/wasm32-unknown-wasip1/release/StringEquality.wasm"
[ -f "${SEQ_WASM}" ] || { echo "error: StringEquality.wasm not linked" >&2; exit 1; }
echo "    linked StringEquality.wasm: $(wc -c < "${SEQ_WASM}") bytes"
if command -v node >/dev/null 2>&1; then
  RUN_MJS="${STRTEST}/run.mjs"
  cat > "${RUN_MJS}" <<'JS'
import { WASI } from 'node:wasi';
import { readFile } from 'node:fs/promises';
const wasi = new WASI({ version: 'preview1', args: ['streq'], env: {}, returnOnExit: true });
const module = await WebAssembly.compile(await readFile(process.argv[2]));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exit(wasi.start(instance));
JS
  SEQ_OUT="$(node --experimental-wasi-unstable-preview1 "${RUN_MJS}" "${SEQ_WASM}")" || {
    echo "${SEQ_OUT}" | sed 's/^/    /'; echo "error: String == fixture FAILED at runtime" >&2; exit 1; }
  echo "${SEQ_OUT}" | sed 's/^/    /'
  echo "${SEQ_OUT}" | grep -q '^ALL-PASS$' || { echo "error: expected ALL-PASS from the fixture" >&2; exit 1; }
else
  echo "    (node not found — linked only; runtime behavior not checked)"
fi

echo "OK: core + worker compile, and an embedded executable links."
echo "    linked Worker.wasm: $(wc -c < "${WASM}") bytes"
