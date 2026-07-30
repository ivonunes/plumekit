// Behavioural tests for the Cloudflare worker runtime's guest gate.
//
// The gate is what keeps one wasm instance from running two requests at once,
// and it has to survive the runtime dropping a request mid-flight. Driven by
// Swift (WorkerRuntimeGateTests), or standalone with `node gate.test.mjs`.
// Exits non-zero on the first failed assertion.
//
// worker.mjs imports ./app.wasm, which only exists inside a built bundle, so the
// module is loaded here with that import stubbed out. Everything else is the
// shipped file, unmodified.

import { readFileSync } from "node:fs";

const workerPath = process.argv[2]
  || new URL("../../runtime/cloudflare/worker.mjs", import.meta.url).pathname;
const source = readFileSync(workerPath, "utf8")
  .replace(/^import wasmModule from "\.\/app\.wasm";$/m, "const wasmModule = null;");
const { createGate } = await import("data:text/javascript," + encodeURIComponent(source));

let failures = 0;
function check(name, condition) {
  if (condition) {
    console.log("  ok   " + name);
  } else {
    failures++;
    console.error("  FAIL " + name);
  }
}
const after = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// A wedged gate leaves its callers pending for ever, which drains node's event
// loop and exits 0 — a hang would read as a pass. `raced` bounds the waits a
// wedged gate would swallow, and the watchdog catches anything else.
const raced = (promise, ms = 1000) => Promise.race([promise, after(ms).then(() => "hung")]);
const watchdog = setTimeout(() => {
  console.error("\nworker runtime: timed out waiting for the gate");
  process.exit(1);
}, 15000);

// A gate with a stall timeout short enough to test, and a count of how often it
// gave up on the call ahead.
function gate(timeoutMs = 50) {
  const stalls = { count: 0 };
  const gated = createGate({ timeoutMs, onStall: () => stalls.count++ });
  return { gated, stalls };
}

// --- the normal case: calls run one at a time, in the order they queued -----
async function testSerializesCalls() {
  console.log("gate: calls run one at a time, in order");
  const { gated, stalls } = gate();
  const events = [];
  let running = 0, overlapped = false;

  const call = (name) => gated(async () => {
    running++;
    if (running > 1) overlapped = true;
    events.push(name);
    await after(5);
    running--;
    return name;
  });

  const results = await Promise.all([call("a"), call("b"), call("c")]);
  check("no two calls ran at once", !overlapped);
  check("ran in the order they queued", events.join("") === "abc");
  check("each caller got its own result", results.join("") === "abc");
  check("no stall declared", stalls.count === 0);
}

// --- a throwing call must not take the gate down with it -------------------
async function testReleasesOnThrow() {
  console.log("gate: a failed call still releases the gate");
  const { gated, stalls } = gate();
  const boom = gated(async () => { throw new Error("boom"); });
  await boom.then(() => check("the error reached the caller", false),
                  (e) => check("the error reached the caller", e.message === "boom"));
  const next = await gated(async () => "ran");
  check("the next call still ran", next === "ran");
  check("no stall declared", stalls.count === 0);
}

// --- the bug this gate exists to survive -----------------------------------
// A request the runtime drops mid-flight never runs the code that would release
// its link. Before the fix that wedged the isolate for good: every later request
// waited on a promise that could never settle, burning wall-clock at zero CPU
// until the client gave up.
async function testRecoversFromAnAbandonedCall() {
  console.log("gate: an abandoned call does not wedge the isolate");
  const { gated, stalls } = gate(50);
  gated(() => new Promise(() => {}));            // never settles, never releases

  const started = Date.now();
  const result = await raced(gated(async () => "ran"));
  check("a later call still ran", result === "ran");
  check("it waited for the stall timeout, not for ever", Date.now() - started < 1000);
  check("the stalled instance was retired once", stalls.count === 1);

  const next = await raced(gated(async () => "ran"));
  check("the gate kept working afterwards", next === "ran");
  check("no further stall declared", stalls.count === 1);
}

// --- and the opposite: a slow call is not mistaken for an abandoned one -----
async function testSlowCallIsNotAStall() {
  console.log("gate: a slow call is left alone");
  const { gated, stalls } = gate(200);
  const slow = gated(async () => { await after(60); return "slow"; });
  const next = gated(async () => "next");
  check("the slow call finished", (await slow) === "slow");
  check("the queued call ran after it", (await next) === "next");
  check("no stall declared", stalls.count === 0);
}

async function run() {
  await testSerializesCalls();
  await testReleasesOnThrow();
  await testRecoversFromAnAbandonedCall();
  await testSlowCallIsNotAStall();

  if (failures === 0) {
    console.log("\nworker runtime: all checks passed");
    process.exit(0);
  } else {
    console.error("\nworker runtime: " + failures + " check(s) failed");
    process.exit(1);
  }
}

run();
