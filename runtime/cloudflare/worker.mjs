// Cloudflare Worker entry for a PlumeKit app (async + host bindings).
//
// Module worker that instantiates the Embedded-Swift module once and, per
// request, marshals bytes in/out AND bridges async host calls (KV, logging) via
// JSPI (JavaScript Promise Integration):
//   • Async host imports are wrapped with `WebAssembly.Suspending`, so when the
//     guest calls one the whole wasm stack suspends until the JS promise
//     resolves, then resumes — transparently to Swift.
//   • The guest entry `plumekit_handle` is wrapped with `WebAssembly.promising`,
//     making it suspendable and promise-returning.
//
// Per-request `env` is routed via a context table keyed by a `ctx` id passed to
// the guest — never a global binding reference, because `env` differs per request
// and the isolate is shared.
//
// No npm dependencies. The wire format mirrors Sources/PlumeKitWorker/WireFormat.swift.
import wasmModule from "./app.wasm";

const METHOD_CODES = { GET: 0, POST: 1, PUT: 2, PATCH: 3, DELETE: 4, HEAD: 5, OPTIONS: 6 };

// Largest request body the guest will accept (wasm linear memory only grows).
const MAX_REQUEST_BYTES = 25 * 1024 * 1024;

let instance;
let promisingHandle;
let promisingQueue;
const ctxTable = new Map();
let nextCtx = 1;
const mem = () => instance.exports.memory.buffer;
const decoder = new TextDecoder();
const utf8 = new TextEncoder();

// WASI shim parameterized by a memory accessor, so both the request isolate and a
// Durable Object isolate (each with its own wasm instance) can reuse it.
function buildWasi(memFn) {
  const wasi = {
    random_get: (ptr, len) => {
      crypto.getRandomValues(new Uint8Array(memFn(), ptr, len));
      return 0;
    },
    fd_write: (fd, iovsPtr, iovsLen, nwrittenPtr) => {
      const view = new DataView(memFn());
      let text = "", written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const base = iovsPtr + i * 8;
        const p = view.getUint32(base, true), l = view.getUint32(base + 4, true);
        text += decoder.decode(new Uint8Array(memFn(), p, l));
        written += l;
      }
      if (text.length) console.log(text.replace(/\n+$/, ""));
      view.setUint32(nwrittenPtr, written, true);
      return 0;
    },
  };
  for (const imp of WebAssembly.Module.imports(wasmModule)) {
    if (imp.module === "wasi_snapshot_preview1" && !(imp.name in wasi)) wasi[imp.name] = () => 0;
  }
  return wasi;
}

function getInstance() {
  if (instance) return instance;

  const wasi = buildWasi(mem);

  // Custom host bindings (the `env` module). KV is the reference binding.
  const env = {
    host_log: (ptr, len) => {
      console.log(decoder.decode(new Uint8Array(mem(), ptr, len)));
    },
    // Wall clock (epoch ms) for the ORM's createdAt/updatedAt. Synchronous.
    host_now: () => Date.now(),
    // get: fetch the value (suspending) and stash it; return its length, or -1.
    host_kv_get: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen) => {
      const slot = ctxTable.get(ctx);
      const kv = slot?.env?.KV;
      if (!kv) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const value = await kv.get(key, "arrayBuffer");
      if (value === null) { slot.stash = null; return -1; }
      slot.stash = new Uint8Array(value);
      return slot.stash.length;
    }),
    // read: copy the stashed value into the guest buffer.
    host_kv_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },
    host_kv_put: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen, valPtr, valLen, ttlSeconds) => {
      const slot = ctxTable.get(ctx);
      const kv = slot?.env?.KV;
      if (!kv) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const value = new Uint8Array(mem(), valPtr, valLen).slice();
      // Workers KV enforces a 60s floor on expirationTtl; 0 means "no expiry".
      const options = ttlSeconds > 0 ? { expirationTtl: Math.max(60, ttlSeconds) } : undefined;
      await kv.put(key, value, options);
      return 0;
    }),

    // SQL via D1. Decode the (sql, params) request, run it, encode typed rows;
    // two-call read like KV. The binding name is `DB` (set in wrangler.toml).
    // Reads go through raw() for POSITIONAL rows: all()'s name-keyed objects
    // collapse duplicate column names (SELECT u.id, c.id ...), silently
    // dropping columns that the native SQLite driver preserves. Writes keep
    // run(), the only call that reports meta (changes / last_row_id).
    host_db_query: new WebAssembly.Suspending(async (ctx, reqPtr, reqLen) => {
      const slot = ctxTable.get(ctx);
      const db = slot?.env?.DB;
      if (!db) { slot.stash = null; return -1; }
      const { sql, params } = decodeQueryRequest(new Uint8Array(mem(), reqPtr, reqLen).slice());
      try {
        const stmt = params.length ? db.prepare(sql).bind(...params) : db.prepare(sql);
        if (isReadStatement(sql)) {
          const raw = await stmt.raw({ columnNames: true });
          const cols = raw.length ? raw[0].map(String) : [];
          slot.stash = encodeQueryRows(cols, raw.slice(1), {});
        } else {
          const out = await stmt.run();
          slot.stash = encodeQueryResult(out.results || [], out.meta || {});
        }
        return slot.stash.length;
      } catch (e) {
        // A D1 error (constraint/syntax) must NOT reject the JSPI promise — that would
        // abandon the whole guest request and leak memory. Log it and return -1 (the
        // guest yields an empty result; embedded Swift can't rethrow it as a catchable
        // error). Check `wrangler tail` for the cause of an unexpectedly empty write.
        console.log("D1 query error: " + String((e && e.message) || e));
        slot.stash = null;
        return -1;
      }
    }),
    host_db_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },

    // N statements in one exchange via D1's native batch() (atomic). Request:
    // u16 count + u32-length-prefixed encodeQueryRequest blobs; response: u16
    // count + u32-length-prefixed per-statement result blobs (host_db_read).
    // batch() returns name-keyed rows (there is no raw() for batches), so
    // duplicate column names across a join collapse — batched reads must
    // alias them, per the SQLDatabase.batch doc.
    host_db_batch: new WebAssembly.Suspending(async (ctx, reqPtr, reqLen) => {
      const slot = ctxTable.get(ctx);
      const db = slot?.env?.DB;
      if (!db) { slot.stash = null; return -1; }
      const bytes = new Uint8Array(mem(), reqPtr, reqLen).slice();
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      let o = 0;
      const count = view.getUint16(o, true); o += 2;
      const statements = [];
      for (let i = 0; i < count; i++) {
        const blobLen = view.getUint32(o, true); o += 4;
        statements.push(decodeQueryRequest(bytes.subarray(o, o + blobLen)));
        o += blobLen;
      }
      try {
        const prepared = statements.map(({ sql, params }) =>
          params.length ? db.prepare(sql).bind(...params) : db.prepare(sql));
        const results = await db.batch(prepared);
        const blobs = results.map((out) => encodeQueryResult(out.results || [], out.meta || {}));
        let total = 2;
        for (const b of blobs) total += 4 + b.length;
        const stash = new Uint8Array(total);
        const dv = new DataView(stash.buffer);
        dv.setUint16(0, blobs.length, true);
        let w = 2;
        for (const b of blobs) {
          dv.setUint32(w, b.length, true); w += 4;
          stash.set(b, w); w += b.length;
        }
        slot.stash = stash;
        return slot.stash.length;
      } catch (e) {
        console.log("D1 batch error: " + String((e && e.message) || e));
        slot.stash = null;
        return -1;
      }
    }),

    // Object storage via R2 (binding `BLOB`). Like KV with delete.
    host_blob_get: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen) => {
      const slot = ctxTable.get(ctx);
      const r2 = slot?.env?.BLOB;
      if (!r2) { slot.stash = null; return -1; }
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const object = await r2.get(key);
      if (object === null) { slot.stash = null; return -1; }
      slot.stash = new Uint8Array(await object.arrayBuffer());
      return slot.stash.length;
    }),
    host_blob_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },
    host_blob_put: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen, valPtr, valLen) => {
      const slot = ctxTable.get(ctx);
      const r2 = slot?.env?.BLOB;
      if (!r2) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const value = new Uint8Array(mem(), valPtr, valLen).slice();
      await r2.put(key, value);
      return 0;
    }),
    host_blob_delete: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen) => {
      const slot = ctxTable.get(ctx);
      const r2 = slot?.env?.BLOB;
      if (!r2) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      await r2.delete(key);
      return 0;
    }),

    // Ephemeral cache via a Workers KV namespace used as a cache (binding `CACHE`),
    // with `expirationTtl`. Best-effort: an unbound namespace just misses. Two-call
    // read like KV.
    host_cache_get: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen) => {
      const slot = ctxTable.get(ctx);
      const cache = slot?.env?.CACHE;
      if (!cache) { slot.stash = null; return -1; }
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const value = await cache.get(key, "arrayBuffer");
      if (value === null) { slot.stash = null; return -1; }
      slot.stash = new Uint8Array(value);
      return slot.stash.length;
    }),
    host_cache_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },
    host_cache_set: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen, valPtr, valLen, ttlSeconds) => {
      const slot = ctxTable.get(ctx);
      const cache = slot?.env?.CACHE;
      if (!cache) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      const value = new Uint8Array(mem(), valPtr, valLen).slice();
      // Workers KV enforces a 60s floor on expirationTtl; 0 means "no expiry".
      const options = ttlSeconds > 0 ? { expirationTtl: Math.max(60, ttlSeconds) } : undefined;
      await cache.put(key, value, options);
      return 0;
    }),
    host_cache_delete: new WebAssembly.Suspending(async (ctx, keyPtr, keyLen) => {
      const slot = ctxTable.get(ctx);
      const cache = slot?.env?.CACHE;
      if (!cache) return -1;
      const key = decoder.decode(new Uint8Array(mem(), keyPtr, keyLen));
      await cache.delete(key);
      return 0;
    }),

    // Enqueue a message to Cloudflare Queues (binding `QUEUE`).
    host_queue_send: new WebAssembly.Suspending(async (ctx, bodyPtr, bodyLen) => {
      const slot = ctxTable.get(ctx);
      const q = slot?.env?.QUEUE;
      if (!q) return -1;
      const body = new Uint8Array(mem(), bodyPtr, bodyLen).slice();
      await q.send(body, { contentType: "bytes" });   // raw bytes round-trip
      return 0;
    }),

    // Transactional email — the Mailer capability. The guest hands a JSON message
    // ({from,to,subject,text,html?,replyTo?}); we POST it to the configured HTTP email
    // provider (env.MAIL_API_URL, optional `Bearer` env.MAIL_API_KEY). No provider
    // configured → log only (dev). Body shape matches Resend / a generic JSON API.
    host_email_send: new WebAssembly.Suspending(async (ctx, ptr, len) => {
      const slot = ctxTable.get(ctx);
      const env = slot?.env ?? {};
      let msg;
      try { msg = JSON.parse(decoder.decode(new Uint8Array(mem(), ptr, len))); }
      catch { return -1; }
      const apiUrl = env.MAIL_API_URL;
      if (!apiUrl) { console.log("[mail] (no MAIL_API_URL) would send:", JSON.stringify(msg)); return 0; }
      try {
        const headers = { "content-type": "application/json" };
        if (env.MAIL_API_KEY) headers.authorization = `Bearer ${env.MAIL_API_KEY}`;
        const res = await fetch(apiUrl, {
          method: "POST",
          headers,
          body: JSON.stringify({ from: msg.from, to: msg.to, subject: msg.subject, text: msg.text, html: msg.html }),
        });
        if (!res.ok) { console.log("[mail] provider rejected:", res.status); return -1; }
        return 0;
      } catch (e) { console.log("[mail] send failed:", e); return -1; }
    }),

    // Originate a broadcast — RPC the channel's DO, which fans out to its
    // sockets. Runs in the request/queue isolate (JSPI works here, unlike the DO).
    host_broadcast: new WebAssembly.Suspending(async (ctx, chanPtr, chanLen, pushPtr, pushLen) => {
      const slot = ctxTable.get(ctx);
      const binding = slot?.env?.CHANNEL;
      if (!binding) return -1;
      const channel = decoder.decode(new Uint8Array(mem(), chanPtr, chanLen));
      const pushes = new Uint8Array(mem(), pushPtr, pushLen).slice();
      const stub = binding.get(binding.idFromName(channel));
      await stub.fetch("https://do/broadcast", { method: "POST", body: pushes });
      return 0;
    }),

    // Outbound HTTP GET via the platform's global fetch. Result = [u16 status][body].
    host_fetch_get: new WebAssembly.Suspending(async (ctx, urlPtr, urlLen) => {
      const slot = ctxTable.get(ctx);
      const url = decoder.decode(new Uint8Array(mem(), urlPtr, urlLen));
      try {
        const response = await fetch(url);
        const body = new Uint8Array(await response.arrayBuffer());
        const out = new Uint8Array(2 + body.length);
        out[0] = response.status & 0xff;
        out[1] = (response.status >> 8) & 0xff;
        out.set(body, 2);
        slot.stash = out;
        return out.length;
      } catch {
        slot.stash = null;
        return -1;
      }
    }),
    host_fetch_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },

    // Full outbound HTTP (method/headers/body) via the platform's global fetch.
    // Request wire: [u8 mLen][method][u32 uLen][url][u16 hCount]
    //               ([u16 nLen][name][u16 vLen][value])* [u32 bLen][body]
    // Result wire:  [u16 status][u16 hCount]([u16][name][u16][value])* [body]
    // (little-endian; mirrors PlumeCore's FetchWire).
    host_fetch_request: new WebAssembly.Suspending(async (ctx, reqPtr, reqLen) => {
      const slot = ctxTable.get(ctx);
      const req = new Uint8Array(mem(), reqPtr, reqLen).slice();
      try {
        const view = new DataView(req.buffer, req.byteOffset, req.byteLength);
        let i = 0;
        const mLen = view.getUint8(i); i += 1;
        const method = decoder.decode(req.subarray(i, i + mLen)); i += mLen;
        const uLen = view.getUint32(i, true); i += 4;
        const url = decoder.decode(req.subarray(i, i + uLen)); i += uLen;
        const hCount = view.getUint16(i, true); i += 2;
        const headers = {};
        for (let h = 0; h < hCount; h++) {
          const nLen = view.getUint16(i, true); i += 2;
          const name = decoder.decode(req.subarray(i, i + nLen)); i += nLen;
          const vLen = view.getUint16(i, true); i += 2;
          headers[name] = decoder.decode(req.subarray(i, i + vLen)); i += vLen;
        }
        const bLen = view.getUint32(i, true); i += 4;
        const body = bLen > 0 ? req.subarray(i, i + bLen) : undefined;
        const response = await fetch(url, { method, headers, body });
        const respBody = new Uint8Array(await response.arrayBuffer());
        const respHeaders = [];
        const enc = new TextEncoder();
        let headerBytes = 0;
        response.headers.forEach((value, name) => {
          const n = enc.encode(name), v = enc.encode(value);
          respHeaders.push([n, v]);
          headerBytes += 4 + n.length + v.length;
        });
        const out = new Uint8Array(4 + headerBytes + respBody.length);
        const outView = new DataView(out.buffer);
        outView.setUint16(0, response.status, true);
        outView.setUint16(2, respHeaders.length, true);
        let o = 4;
        for (const [n, v] of respHeaders) {
          outView.setUint16(o, n.length, true); o += 2;
          out.set(n, o); o += n.length;
          outView.setUint16(o, v.length, true); o += 2;
          out.set(v, o); o += v.length;
        }
        out.set(respBody, o);
        slot.stash = out;
        return out.length;
      } catch {
        slot.stash = null;
        return -1;
      }
    }),

    // Secrets/vars live on `env` and read synchronously (NOT Suspending). get
    // stashes the UTF-8 value and returns its length (-1 if unset); read copies.
    host_secret_get: (ctx, namePtr, nameLen) => {
      const slot = ctxTable.get(ctx);
      const name = decoder.decode(new Uint8Array(mem(), namePtr, nameLen));
      const value = slot?.env?.[name];
      if (value === undefined || value === null) { slot.stash = null; return -1; }
      slot.stash = utf8.encode(String(value));
      return slot.stash.length;
    },
    host_secret_read: (ctx, dstPtr) => {
      const slot = ctxTable.get(ctx);
      if (slot?.stash?.length) new Uint8Array(mem()).set(slot.stash, dstPtr);
    },
  };

  instance = new WebAssembly.Instance(wasmModule, { wasi_snapshot_preview1: wasi, env });
  instance.exports._initialize();
  promisingHandle = WebAssembly.promising(instance.exports.plumekit_handle);
  if (instance.exports.plumekit_queue) {
    promisingQueue = WebAssembly.promising(instance.exports.plumekit_queue);
  }
  return instance;
}

// --- SQL wire codec (mirrors Sources/PlumeKitWorker/D1Database.swift) ---
function decodeQueryRequest(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let o = 0;
  const u8 = () => bytes[o++];
  const u16 = () => { const x = view.getUint16(o, true); o += 2; return x; };
  const i64 = () => { const x = view.getBigInt64(o, true); o += 8; return x; };
  const f64 = () => { const x = view.getFloat64(o, true); o += 8; return x; };
  const u32 = () => { const x = view.getUint32(o, true); o += 4; return x; };
  const str = (n) => { const s = decoder.decode(bytes.subarray(o, o + n)); o += n; return s; };
  const sql = str(u32());
  const count = u16();
  const params = [];
  for (let i = 0; i < count; i++) {
    switch (u8()) {
      case 1: { const v = i64(); params.push(v >= -9007199254740991n && v <= 9007199254740991n ? Number(v) : v); break; } // integer (BigInt beyond 2^53 to keep precision)
      case 2: params.push(f64()); break;                    // double
      case 3: params.push(str(u32())); break;               // text
      case 4: { const n = u32(); params.push(bytes.subarray(o, o + n)); o += n; break; } // blob
      default: params.push(null);
    }
  }
  return { sql, params };
}

// Statements that only read rows are safe to run via D1's raw() (which loses
// meta but keeps duplicate column names). A WITH prefix can front a write
// (WITH cte AS (...) DELETE ...), so those only count as reads when no write
// verb appears anywhere.
function isReadStatement(sql) {
  const s = sql.replace(/^\s*(--[^\n]*\n|\/\*[\s\S]*?\*\/|\s+)*/g, "");
  if (/^(select|values|explain|pragma)\b/i.test(s)) return true;
  return /^with\b/i.test(s) && !/\b(insert|update|delete|replace)\b/i.test(s);
}

// Object-keyed rows (from all()/run()) reduce to positional via the first
// row's keys — fine for writes and RETURNING, where names can't collide.
function encodeQueryResult(rows, meta) {
  const cols = rows.length ? Object.keys(rows[0]) : [];
  return encodeQueryRows(cols, rows.map((r) => cols.map((c) => r[c])), meta);
}

function encodeQueryRows(cols, rows, meta) {
  const a = [];
  const dv = new DataView(new ArrayBuffer(8));
  const u8 = (v) => a.push(v & 0xff);
  const u16 = (v) => a.push(v & 0xff, (v >> 8) & 0xff);
  const u32 = (v) => a.push(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff);
  const i64 = (v) => { dv.setBigInt64(0, BigInt.asIntN(64, BigInt(v)), true); for (let i = 0; i < 8; i++) a.push(dv.getUint8(i)); };
  const f64 = (v) => { dv.setFloat64(0, v, true); for (let i = 0; i < 8; i++) a.push(dv.getUint8(i)); };
  const enc = new TextEncoder();
  // 32-bit length: D1 TEXT values (article bodies, JSON) exceed 64 KiB; a u16 prefix
  // would wrap and desync the whole result. Pairs with the guest's u32 text reader.
  const lp = (s) => { const b = enc.encode(s); u32(b.length); for (const x of b) a.push(x); };
  u16(cols.length);
  for (const c of cols) lp(c);
  u32(rows.length);
  for (const row of rows) {
    for (let i = 0; i < cols.length; i++) {
      const v = row[i];
      if (v === null || v === undefined) u8(0);
      else if (typeof v === "bigint") { u8(1); i64(v); }
      else if (typeof v === "boolean") { u8(1); i64(v ? 1 : 0); }
      else if (typeof v === "number") { if (Number.isInteger(v)) { u8(1); i64(v); } else { u8(2); f64(v); } }
      else if (typeof v === "string") { u8(3); lp(v); }
      // D1 returns BLOB columns as Array<number> or Uint8Array (not always ArrayBuffer);
      // treat all three as bytes so a blob doesn't get serialized as its text form.
      else if (v instanceof ArrayBuffer || v instanceof Uint8Array || Array.isArray(v)) {
        const b = v instanceof Uint8Array ? v : new Uint8Array(v);
        u8(4); u32(b.length); for (const x of b) a.push(x);
      }
      else { u8(3); lp(String(v)); }
    }
  }
  u32(meta?.changes || 0);
  i64(meta?.last_row_id || 0);
  return Uint8Array.from(a);
}

function encodeRequest(method, path, query, headers, body) {
  const encoder = new TextEncoder();
  const chunks = [];
  const u8 = (v) => chunks.push(Uint8Array.of(v & 0xff));
  const u16 = (v) => chunks.push(Uint8Array.of(v & 0xff, (v >> 8) & 0xff));
  const u32 = (v) => chunks.push(Uint8Array.of(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff));
  const lp = (s) => { const b = encoder.encode(s); u16(b.length); chunks.push(b); };
  u8(METHOD_CODES[method] ?? 0);
  lp(path);
  lp(query);
  u16(headers.length);
  for (const [name, value] of headers) { lp(name); lp(value); }
  u32(body.length);
  chunks.push(body);
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

function decodeResponse(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 0;
  const status = view.getUint16(off, true); off += 2;
  const headerCount = view.getUint16(off, true); off += 2;
  const headers = [];
  for (let i = 0; i < headerCount; i++) {
    const nl = view.getUint16(off, true); off += 2;
    const name = decoder.decode(bytes.subarray(off, off + nl)); off += nl;
    const vl = view.getUint16(off, true); off += 2;
    const value = decoder.decode(bytes.subarray(off, off + vl)); off += vl;
    headers.push([name, value]);
  }
  const bodyLen = view.getUint32(off, true); off += 4;
  return { status, headers, body: bytes.slice(off, off + bodyLen) };
}

// One handler invocation in flight at a time per isolate (v1 simplification):
// the single instance shares linear memory + the cooperative executor across
// requests, so serializing avoids interleaving hazards. Removable once per-ctx
// state is fully threaded through the guest.
let lock = Promise.resolve();
async function serialized(fn) {
  const prev = lock;
  let release;
  lock = new Promise((r) => (release = r));
  await prev;
  try { return await fn(); } finally { release(); }
}

// Real-time channel: a Durable Object hosting its OWN wasm instance. The
// DO is long-lived + sharded (one per channel id); it HIBERNATES between messages,
// so all state is read/written through DO storage and rebuilt every event — never
// trusted in guest memory. Each event is run-to-completion.
//
// Sessions: every socket carries its verified token subject (in the
// hibernation attachment); open / message / close each dispatch an EVENT into the
// guest with that subject + the wall clock + a random seed (the guest has no
// suspending imports here). Effects come back as store writes, deferred SQL
// statements (applied against env.DB — the DO can await D1 even though the guest
// cannot), targeted/broadcast pushes, and cross-channel broadcasts. Wire formats
// mirror Sources/PlumeCore/ChannelWire.swift.
export class ChannelDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.instance = null;      // rebuilt lazily; constructor re-runs after hibernation
    this.promisingChannel = null;
    this.stash = null;
    this.kv = null;            // in-memory state cache, loaded once per isolate lifetime
    this.room = null;          // the "__room" value, cached to skip redundant reads/writes
  }

  // Per-DO wasm instance. No Suspending imports — JSPI doesn't instantiate in a DO
  // isolate, so the handler is synchronous and the DO marshals all async I/O.
  ensureInstance() {
    if (this.instance) return;
    const self = this;
    const memFn = () => self.instance.exports.memory.buffer;
    const wasi = buildWasi(memFn);
    const env = {
      host_log: (ptr, len) => console.log(decoder.decode(new Uint8Array(memFn(), ptr, len))),
      host_now: () => Date.now(),
    };
    for (const imp of WebAssembly.Module.imports(wasmModule)) {
      if (imp.module === "env" && !(imp.name in env)) env[imp.name] = () => 0;   // unused in the DO
    }
    self.instance = new WebAssembly.Instance(wasmModule, { wasi_snapshot_preview1: wasi, env });
    self.instance.exports._initialize();
  }

  async fetch(request) {
    const url = new URL(request.url);
    // A broadcast RPC'd from the request/queue isolate — fan the pushes out.
    if (url.pathname === "/broadcast") {
      const blob = new Uint8Array(await request.arrayBuffer());
      this.fanOut(blob, 0);
      return new Response("ok");
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const room = url.searchParams.get("room") || "default";
    const token = url.searchParams.get("token") || "";
    // Signed subscriptions: when a signing key is configured, reject any
    // subscribe without a valid channel-scoped token (verified in the guest).
    const signingKey = this.env.CHANNEL_SIGNING_KEY;
    if (signingKey) {
      this.ensureInstance();
      const now = Math.floor(Date.now() / 1000);
      if (!this.verifyToken(token, room, signingKey, now)) {
        return new Response("forbidden", { status: 403 });
      }
    }
    // The socket's verified subject = the hex-decoded first token segment
    // (bound into the HMAC the guest just verified). Unsigned dev mode adopts it
    // as-is. Kept in the hibernation attachment (2KB limit — keep subjects lean).
    const subject = tokenSubject(token);
    const kind = url.searchParams.get("kind") === "payload" ? 1 : 0;
    // Keepalive: the runtime answers a literal "ping" with "pong" WITHOUT waking
    // a hibernated DO — no request billed, no dispatch. Clients hold idle
    // sockets open with these; anything meaningful still uses real messages.
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    const pair = new WebSocketPair();
    this.state.acceptWebSocket(pair[1]);   // Hibernation API
    pair[1].serializeAttachment({ kind, subject, room });
    // Dispatch the OPEN event before returning; its pushes (e.g. a snapshot to
    // the joiner) are queued on the accepted socket and flush after the 101.
    await this.dispatchEvent(0, room, subject, new Uint8Array(0));
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  // Verify a signed subscription token via the guest (sync, timing-safe in Swift).
  verifyToken(token, channel, key, now) {
    const ex = this.instance.exports;
    const tb = utf8.encode(token), cb = utf8.encode(channel), kb = utf8.encode(key);
    const tp = ex.plumekit_alloc(tb.length); new Uint8Array(ex.memory.buffer).set(tb, tp);
    const cp = ex.plumekit_alloc(cb.length); new Uint8Array(ex.memory.buffer).set(cb, cp);
    const kp = ex.plumekit_alloc(kb.length); new Uint8Array(ex.memory.buffer).set(kb, kp);
    const result = ex.plumekit_channel_verify(tp, tb.length, cp, cb.length, kp, kb.length, now);
    ex.plumekit_free(tp, tb.length); ex.plumekit_free(cp, cb.length); ex.plumekit_free(kp, kb.length);
    return result === 1;
  }

  // Decode a pushes blob ([u16 n]([u8 kind][u16 subjLen][subject][u32 len][bytes])*)
  // at offset `p` and deliver: subject "" -> every subscriber of the kind; otherwise
  // only sockets whose attachment subject matches. Returns the end offset.
  fanOut(blob, p) {
    const rU16 = () => { const v = blob[p] | (blob[p + 1] << 8); p += 2; return v; };
    const rU32 = () => { const v = blob[p] + blob[p + 1] * 256 + blob[p + 2] * 65536 + blob[p + 3] * 16777216; p += 4; return v; };
    const n = rU16();
    const sockets = this.state.getWebSockets();
    for (let i = 0; i < n; i++) {
      const kind = blob[p]; p += 1;
      const sl = rU16(); const subject = decoder.decode(blob.slice(p, p + sl)); p += sl;
      const len = rU32(); const payload = blob.slice(p, p + len); p += len;
      const text = decoder.decode(payload);
      for (const s of sockets) {
        let att;
        try { att = s.deserializeAttachment(); } catch { continue; }
        if (!att || att.kind !== kind) continue;
        if (subject !== "" && att.subject !== subject) continue;
        try { s.send(text); } catch {}
      }
    }
    return p;
  }

  // Load state -> run the guest event handler -> apply effects (store writes, SQL
  // against env.DB, pushes, cross-channel broadcasts, the alarm request).
  // kind: 0 open, 1 message, 2 close, 3 alarm.
  //
  // SERIALIZED: a Durable Object interleaves concurrent events at await points,
  // so two simultaneous messages would each load the state snapshot BEFORE the
  // other's writes land — a lost-update race the native hub (an actor) can't
  // have. The promise chain gives channel events actor semantics here too.
  async dispatchEvent(eventKind, room, subject, msg) {
    const prev = this._dispatchLock ?? Promise.resolve();
    let release;
    this._dispatchLock = new Promise((r) => (release = r));
    await prev;
    try {
      return await this.dispatchEventUnlocked(eventKind, room, subject, msg);
    } finally {
      release();
    }
  }

  async dispatchEventUnlocked(eventKind, room, subject, msg) {
    this.ensureInstance();
    const exports = this.instance.exports;
    const memBuf = () => exports.memory.buffer;

    // Remember the room id host-side (hidden "__room" key, stripped from the
    // guest snapshot) so the alarm() handler — which has no request — knows it.
    // Written only when it changes: a DO hosts one room for life, so re-putting
    // it per event would bill a storage write for every message.
    if (eventKind !== 3 && this.room !== room) {
      await this.state.storage.put("__room", utf8.encode(room));
      this.room = room;
    }

    // The room's live state, loaded ONCE per isolate lifetime (cold start /
    // post-hibernation wake) and maintained write-through in the effects pass —
    // never re-listed per event: on SQLite-backed DOs every storage.list()
    // bills one row read per stored key, which multiplied by a fast alarm tick
    // is ruinous. Empty values are deletion tombstones written before the
    // effects wire's "empty = delete" convention existed — purge them from
    // storage on sight (bulk deletes, 128 keys per call).
    if (this.kv === null) {
      const loaded = await this.state.storage.list();
      const kv = new Map();
      const dead = [];
      for (const [key, value] of loaded) {
        if (key.startsWith("__")) continue;
        const bytes = (value instanceof Uint8Array) ? value : utf8.encode(String(value));
        if (bytes.length === 0) dead.push(key);
        else kv.set(key, bytes);
      }
      for (let i = 0; i < dead.length; i += 128) {
        await this.state.storage.delete(dead.slice(i, i + 128));
      }
      this.kv = kv;
    }

    // Encode the state snapshot: [u16 n]([u16 keyLen][key][u32 valLen][val])*
    const all = this.kv;
    const u16 = (n) => [n & 0xff, (n >> 8) & 0xff];
    const u32 = (n) => [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >>> 24) & 0xff];
    const u64 = (n) => {                       // BigInt-safe little-endian
      const big = BigInt(n); const out = [];
      for (let i = 0n; i < 8n; i++) out.push(Number((big >> (8n * i)) & 0xffn));
      return out;
    };
    const stateParts = [];
    let stateLen = 2;
    for (const [key, value] of all) {
      const kb = utf8.encode(key);
      const vb = (value instanceof Uint8Array) ? value : utf8.encode(String(value));
      stateParts.push({ kb, vb });
      stateLen += 2 + kb.length + 4 + vb.length;
    }
    const state = new Uint8Array(stateLen);
    let o = 0;
    const put = (arr) => { state.set(arr, o); o += arr.length; };
    put(u16(stateParts.length));
    for (const { kb, vb } of stateParts) { put(u16(kb.length)); put(kb); put(u32(vb.length)); put(vb); }

    // Encode the event meta (mirrors ChannelEventMeta):
    // [u8 kind][u16 roomLen][room][u16 subjectLen][subject][u64 now][u64 entropy]
    const rb = utf8.encode(room), sb = utf8.encode(subject);
    const entropyBytes = new Uint8Array(8);
    crypto.getRandomValues(entropyBytes);
    const meta = new Uint8Array(1 + 2 + rb.length + 2 + sb.length + 8 + 8);
    let m = 0;
    meta[m++] = eventKind;
    meta.set(u16(rb.length), m); m += 2; meta.set(rb, m); m += rb.length;
    meta.set(u16(sb.length), m); m += 2; meta.set(sb, m); m += sb.length;
    meta.set(u64(Date.now()), m); m += 8;
    meta.set(entropyBytes, m); m += 8;

    // Run the guest event handler.
    const alloc = (bytes) => {
      const ptr = exports.plumekit_alloc(bytes.length);
      new Uint8Array(memBuf()).set(bytes, ptr);
      return ptr;
    };
    const statePtr = alloc(state), metaPtr = alloc(meta), msgPtr = alloc(msg);
    const descPtr = exports.plumekit_channel_event(statePtr, state.length, metaPtr, meta.length, msgPtr, msg.length);

    const view = new DataView(memBuf());
    const resultPtr = view.getUint32(descPtr, true);
    const resultLen = view.getUint32(descPtr + 4, true);
    const result = new Uint8Array(memBuf()).slice(resultPtr, resultPtr + resultLen);
    exports.plumekit_free(statePtr, state.length);
    exports.plumekit_free(metaPtr, meta.length);
    exports.plumekit_free(msgPtr, msg.length);
    exports.plumekit_free(resultPtr, resultLen);
    exports.plumekit_free(descPtr, 8);

    // Decode + apply effects, mirroring encodeChannelEffects: store writes ->
    // SQL statements -> pushes -> cross-channel broadcasts. SQL runs BEFORE pushes
    // so anything a push tells a client to fetch is already persisted.
    let p = 0;
    const rU16 = () => { const v = result[p] | (result[p + 1] << 8); p += 2; return v; };
    const rU32 = () => { const v = result[p] + result[p + 1] * 256 + result[p + 2] * 65536 + result[p + 3] * 16777216; p += 4; return v; };
    const rU64 = () => { let v = 0n; for (let i = 0n; i < 8n; i++) { v |= BigInt(result[p]) << (8n * i); p += 1; } return v; };
    // Store writes: last write per key wins (a handler often saves the same
    // record several times in one dispatch — one billed write, not N). Keys
    // starting "~" are VOLATILE: they live in this isolate's memory only and
    // never touch billed storage (lost on hibernation — by design, for
    // respawnable simulation state). Empty value = delete, per the wire's
    // deletion convention.
    const writeCount = rU16();
    const finalWrites = new Map();
    for (let i = 0; i < writeCount; i++) {
      const kl = rU16(); const key = decoder.decode(result.slice(p, p + kl)); p += kl;
      const vl = rU32(); const val = result.slice(p, p + vl); p += vl;
      finalWrites.set(key, val);
    }
    for (const [key, val] of finalWrites) {
      if (val.length === 0) {
        if (!key.startsWith("~")) await this.state.storage.delete(key);
        this.kv.delete(key);
      } else {
        if (!key.startsWith("~")) await this.state.storage.put(key, val);
        this.kv.set(key, val);
      }
    }
    const stmtCount = rU16();
    for (let i = 0; i < stmtCount; i++) {
      const sl = rU32(); const sql = decoder.decode(result.slice(p, p + sl)); p += sl;
      const paramCount = rU16();
      const params = [];
      for (let j = 0; j < paramCount; j++) {
        const type = result[p]; p += 1;
        if (type === 0) params.push(null);
        else if (type === 1) { const raw = rU64(); params.push(Number(BigInt.asIntN(64, raw))); }
        else if (type === 2) {
          const raw = rU64();
          const buf = new DataView(new ArrayBuffer(8));
          buf.setBigUint64(0, raw, true);
          params.push(buf.getFloat64(0, true));
        } else {
          const len = rU32(); const bytes = result.slice(p, p + len); p += len;
          params.push(type === 3 ? decoder.decode(bytes) : bytes);
        }
      }
      if (this.env.DB) {
        // console.error, deliberately: a failed deferred write means live play
        // is no longer persisting (e.g. a daily limit hit) — it must be visible
        // to log alerts, not buried in info noise. Gameplay itself carries on.
        try { await this.env.DB.prepare(sql).bind(...params).run(); }
        catch (e) { console.error(`channel sql failed (room ${room}):`, sql, e); }
      } else {
        console.log("channel sql skipped (no DB binding):", sql);
      }
    }
    p = this.fanOut(result, p);

    // Origination point #3: cross-channel broadcasts from inside the handler — RPC
    // each target channel's DO with a standalone pushes blob.
    const broadcastCount = rU16();
    for (let i = 0; i < broadcastCount; i++) {
      const cl = rU16(); const channel = decoder.decode(result.slice(p, p + cl)); p += cl;
      const start = p;                                 // re-slice the pushes sub-blob verbatim
      const pc = rU16();
      for (let j = 0; j < pc; j++) { p += 1; const sl = rU16(); p += sl; const l = rU32(); p += l; }
      const pushesBlob = result.slice(start, p);
      if (this.env.CHANNEL) {
        const stub = this.env.CHANNEL.get(this.env.CHANNEL.idFromName(channel));
        await stub.fetch("https://do/broadcast", { method: "POST", body: pushesBlob });
      }
    }

    // The room's alarm request — 1 = (re)schedule, 2 = cancel, 0 = leave.
    if (p < result.length) {
      const flag = result[p]; p += 1;
      if (flag === 1) {
        const atMs = Number(BigInt.asIntN(64, rU64()));
        await this.state.storage.setAlarm(atMs);
      } else if (flag === 2) {
        await this.state.storage.deleteAlarm();
      }
    }
  }

  // The DO alarm: dispatch a room-level event into the guest (no subject).
  async alarm() {
    if (this.room === null) {
      const roomBytes = await this.state.storage.get("__room");
      this.room = roomBytes ? decoder.decode(roomBytes) : "default";
    }
    await this.dispatchEvent(3, this.room, "", new Uint8Array(0));
  }

  attachmentOf(ws) {
    try { return ws.deserializeAttachment() || {}; } catch { return {}; }
  }

  async webSocketMessage(ws, message) {
    const att = this.attachmentOf(ws);
    const msg = (typeof message === "string") ? utf8.encode(message) : new Uint8Array(message);
    await this.dispatchEvent(1, att.room || "default", att.subject || "", msg);
  }

  async webSocketClose(ws, code, reason, wasClean) {
    const att = this.attachmentOf(ws);
    try { await this.dispatchEvent(2, att.room || "default", att.subject || "", new Uint8Array(0)); }
    catch (e) { console.log("channel close event failed:", e); }
    try { ws.close(code, "bye"); } catch {}
  }
  async webSocketError(ws, error) { console.log("channel ws error:", error); }
}

// The (unverified here — the guest verified the HMAC) subject a token carries:
// hex(subject) "." expiry "." hex(sig). "" when absent/malformed.
function tokenSubject(token) {
  const first = token.split(".")[0] || "";
  if (first.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(first)) return "";
  const bytes = new Uint8Array(first.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(first.slice(i * 2, i * 2 + 2), 16);
  return decoder.decode(bytes);
}

export default {
  async fetch(request, env) {
    const channelURL = new URL(request.url);
    if (env.CHANNEL && channelURL.pathname === "/channel") {
      const room = channelURL.searchParams.get("room") || "default";
      const stub = env.CHANNEL.get(env.CHANNEL.idFromName(room));   // shard per room
      return stub.fetch(request);
    }
    getInstance();
    return await serialized(async () => {
      const ctx = nextCtx++;
      ctxTable.set(ctx, { env, stash: null });
      try {
        const url = new URL(request.url);
        const headers = [];
        for (const [name, value] of request.headers) headers.push([name, value]);
        const body = new Uint8Array(await request.arrayBuffer());
        // Cap the request body so a huge upload can't grow the isolate's linear memory
        // without bound (wasm memory only grows).
        if (body.length > MAX_REQUEST_BYTES) {
          return new Response("413 Payload Too Large", { status: 413 });
        }
        const query = url.search.startsWith("?") ? url.search.slice(1) : url.search;
        const wire = encodeRequest(request.method, url.pathname, query, headers, body);

        let reqPtr = 0, respPtr = 0, respLen = 0, descPtr = 0;
        try {
          reqPtr = instance.exports.plumekit_alloc(wire.length);
          new Uint8Array(mem()).set(wire, reqPtr);

          descPtr = await promisingHandle(ctx, reqPtr, wire.length);

          const view = new DataView(mem());
          respPtr = view.getUint32(descPtr, true);
          respLen = view.getUint32(descPtr + 4, true);
          const respBytes = new Uint8Array(mem()).slice(respPtr, respPtr + respLen);

          const decoded = decodeResponse(respBytes);
          const responseHeaders = new Headers();
          for (const [name, value] of decoded.headers) responseHeaders.append(name, value);
          // The Response constructor rejects a status outside 200-599; a bad guest
          // status becomes a plain 500 rather than an opaque thrown error.
          const status = decoded.status >= 200 && decoded.status <= 599 ? decoded.status : 500;
          return new Response(decoded.body, { status, headers: responseHeaders });
        } finally {
          // Free guest allocations even if the handle rejects (wasm memory only grows).
          if (reqPtr) instance.exports.plumekit_free(reqPtr, wire.length);
          if (respPtr) instance.exports.plumekit_free(respPtr, respLen);
          if (descPtr) instance.exports.plumekit_free(descPtr, 8);
        }
      } finally {
        ctxTable.delete(ctx);
      }
    });
  },

  // Cron Triggers: wrangler's `crons` invoke this once per matching minute. We
  // forward a schedule-tick envelope through the guest's plumekit_queue — the same
  // dispatcher jobs use — and the guest runs whichever scheduled tasks are due
  // (matched against the wall clock, so one `* * * * *` cron drives them all).
  async scheduled(event, env, ctx) {
    getInstance();
    await serialized(async () => {
      const callCtx = nextCtx++;
      ctxTable.set(callCtx, { env, stash: null });
      try {
        // Envelope framing: [u16 nameLen][name][payload]; the payload is the tick's
        // epoch seconds (ASCII decimal) — the guest matches cadences against it.
        const encoder = new TextEncoder();
        const name = encoder.encode("plumekit.schedule.tick");
        const epoch = encoder.encode(String(Math.floor((event.scheduledTime || Date.now()) / 1000)));
        const bytes = new Uint8Array(2 + name.length + epoch.length);
        bytes[0] = (name.length >> 8) & 0xff;
        bytes[1] = name.length & 0xff;
        bytes.set(name, 2);
        bytes.set(epoch, 2 + name.length);
        const ptr = instance.exports.plumekit_alloc(bytes.length);
        new Uint8Array(mem()).set(bytes, ptr);
        try {
          await promisingQueue(callCtx, ptr, bytes.length);
        } finally {
          instance.exports.plumekit_free(ptr, bytes.length);
        }
      } catch (e) {
        console.log("scheduled handler error:", e);
      } finally {
        ctxTable.delete(callCtx);
      }
    });
  },

  // Queue consumer: workerd delivers a batch of messages; we dispatch each through
  // the guest's plumekit_queue (the job registry). Serialized like fetch (one guest
  // call at a time). Each message body is the job envelope bytes the producer sent.
  async queue(batch, env) {
    getInstance();
    for (const message of batch.messages) {
      await serialized(async () => {
        const ctx = nextCtx++;
        ctxTable.set(ctx, { env, stash: null });
        try {
          let bytes = message.body;   // sent with contentType "bytes" → ArrayBuffer
          if (bytes instanceof ArrayBuffer) bytes = new Uint8Array(bytes);
          else if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
          const ptr = instance.exports.plumekit_alloc(bytes.length);
          new Uint8Array(mem()).set(bytes, ptr);
          try {
            await promisingQueue(ctx, ptr, bytes.length);
          } finally {
            instance.exports.plumekit_free(ptr, bytes.length);
          }
          message.ack();
        } catch (e) {
          console.log("queue handler error:", e);
          message.retry();
        } finally {
          ctxTable.delete(ctx);
        }
      });
    }
  },
};
