// Realtime conformance over the wire — driven by scripts/conformance.sh.
// Emits labelled lines the shell asserts on. No client library; raw WebSocket.
const P = process.argv[2];
const B = `http://127.0.0.1:${P}`;
const out = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function token(room) { return (await (await fetch(`${B}/channel-token?room=${room}`)).text()).trim(); }
function conn(room, kind, tok) {
  return new Promise((res) => {
    const got = [];
    const url = `ws://127.0.0.1:${P}/channel?room=${room}`
      + (kind ? `&kind=${kind}` : "") + (tok ? `&token=${tok}` : "");
    const ws = new WebSocket(url);
    ws.onopen = () => res({ ws, got });
    ws.onerror = () => res({ ws: null, got });
    ws.onmessage = (e) => got.push(e.data);
    setTimeout(() => res({ ws, got }), 800);
  });
}

// 1. signed subscribe + payload kinds (one channel, fragment + typed payload)
const tok = await token("lobby");
const f = await conn("lobby", "fragment", tok);
const p = await conn("lobby", "payload", tok);
await sleep(200);
f.ws && f.ws.send("hi");
await sleep(400);
if (f.got[0]) out.push("FRAGMENT:" + f.got[0]);
if (p.got[0]) out.push("PAYLOAD:" + p.got[0]);

// 2. forged token rejected (receives nothing)
const forged = await conn("lobby", "fragment", tok + "ff");
await sleep(150);
f.ws && f.ws.send("again");
await sleep(400);
out.push("FORGED:" + (forged.got.length === 0 ? "rejected" : "accepted"));

// 3. model-driven broadcast carries a stream action (prepend) on the posts channel
const ptok = await token("posts");
const ps = await conn("posts", "fragment", ptok);
await sleep(150);
await fetch(`${B}/posts/broadcast?title=Conf`);
await sleep(500);
if (ps.got[0]) out.push("ACTION:" + ps.got[0]);

// 4. reconnection resync directive
const rc = await conn("lobby", "payload", tok);
await sleep(150);
rc.ws && rc.ws.send("resync:0");
await sleep(400);
const rs = rc.got.find((x) => String(x).includes("resync"));
if (rs) out.push("RESYNC:" + rs);

console.log(out.join("\n"));
process.exit(0);
