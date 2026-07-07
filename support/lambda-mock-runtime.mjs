// A mock AWS Lambda Runtime API. Lets the `provided.al2` Lambda binary run as a plain
// local process: this serves `/invocation/next` (feeding API Gateway events) and
// `/invocation/<id>/response` (capturing the app's response), while every AWS call the
// app makes goes to LocalStack via AWS_ENDPOINT_URL. Used by support/aws-localstack.sh.
//
//   node lambda-mock-runtime.mjs <path-to-Lambda-binary>
//
// Exits 0 when every route returned 200 with the expected body, non-zero otherwise.
import http from "node:http";
import { spawn } from "node:child_process";

const lambdaBin = process.argv[2];
if (!lambdaBin) {
  console.error("usage: lambda-mock-runtime.mjs <lambda-binary>");
  process.exit(2);
}

// Routes to exercise — each hits a LocalStack service (DynamoDB / SSM / SQS) or is pure.
const cases = [
  { name: "GET /count",           path: "/count",           expect: (b) => /count=\d+/.test(b) },
  { name: "GET /cache",           path: "/cache",           expect: (b) => /cache hits=\d+/.test(b) },
  { name: "GET /config/GREETING", path: "/config/GREETING", expect: (b) => b.includes("GREETING=set") },
  { name: "GET /enqueue",         path: "/enqueue",         expect: (b) => b.includes("enqueued") },
  { name: "GET /healthz",         path: "/healthz",         expect: (b) => b.includes('"status":"ok"') },
];

const event = (c) =>
  JSON.stringify({ requestContext: { http: { method: "GET" } }, rawPath: c.path, rawQueryString: "" });

let index = 0;
const results = [];
let child;

const server = http.createServer((req, res) => {
  const url = req.url || "";
  if (req.method === "GET" && url.endsWith("/invocation/next")) {
    if (index >= cases.length) return;            // done — leave the poll hanging; child gets killed
    res.setHeader("Lambda-Runtime-Aws-Request-Id", "req-" + index);
    res.setHeader("Content-Type", "application/json");
    res.writeHead(200);
    res.end(event(cases[index]));
    return;
  }
  const m = url.match(/\/invocation\/(.+)\/(response|error)$/);
  if (req.method === "POST" && m) {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => {
      res.writeHead(202);
      res.end('{"status":"OK"}');
      const c = cases[index];
      let ok = false, decoded = "";
      try {
        const obj = JSON.parse(body);
        decoded = obj.isBase64Encoded ? Buffer.from(obj.body || "", "base64").toString() : (obj.body || "");
        ok = obj.statusCode === 200 && c.expect(decoded);
      } catch { /* ok stays false */ }
      results.push({ name: c.name, ok });
      console.log(`${ok ? "ok  " : "FAIL"}  ${c.name} -> ${decoded.slice(0, 60)}`);
      index++;
      if (index >= cases.length) finish();
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

function finish() {
  const failed = results.filter((r) => !r.ok);
  try { child && child.kill("SIGKILL"); } catch { /* already gone */ }
  server.close();
  if (failed.length) {
    console.error(`\n${failed.length} route(s) failed against LocalStack`);
    process.exit(1);
  }
  console.log(`\nAll ${results.length} routes served correctly against LocalStack.`);
  process.exit(0);
}

server.listen(0, "127.0.0.1", () => {
  const port = server.address().port;
  child = spawn(lambdaBin, [], {
    env: { ...process.env, AWS_LAMBDA_RUNTIME_API: `127.0.0.1:${port}` },
    stdio: ["ignore", "inherit", "inherit"],
  });
  child.on("exit", (code) => {
    if (index < cases.length) {
      console.error(`Lambda exited early (code ${code}) before all routes ran`);
      process.exit(1);
    }
  });
});

setTimeout(() => {
  console.error("timed out waiting for the Lambda to serve all routes");
  try { child && child.kill("SIGKILL"); } catch { /* ignore */ }
  process.exit(1);
}, 60000);
