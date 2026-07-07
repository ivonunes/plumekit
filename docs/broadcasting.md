# Model-driven broadcasting

A model change renders a fragment and fans it out over a channel to subscribers,
with **no request in scope**. This connects the model layer and the renderer to the
real-time layer, and adds the security piece broadcasting makes mandatory: **signed
subscriptions**. Everything routes through the `Channel` abstraction and the
`SecretProvider` only (no platform type), so it works identically on the native
server and Cloudflare.

## Originating a broadcast

A model declares its broadcast target + payloads by conforming to `Broadcastable`,
naming a `ChannelID` and the pushes: a fragment rendered with no request, plus a
typed payload. No socket, no DO:

```swift
extension Post: Broadcastable {
    static func broadcastChannel(for m: Post) -> ChannelID { ChannelID("posts") }
    static func broadcastPushes(for m: Post) -> [ChannelPush] {
        var env = StreamEnvelope()
        env.add(.prepend, target: "posts") { html in html.text(m.title) }   // stream action
        let payload = JSONValue.object([("id", .int(Int64(m.id))), ("title", .string(m.title))]).serialize()
        return [ChannelPush(kind: .fragment, bytes: env.bytes),
                ChannelPush(kind: .payload, bytes: payload)]
    }
}

let post = Post(title: title); _ = try await post.save(in: db)
await broadcast(post, via: broadcaster)     // model → channel; no request
```

The `Broadcaster` capability (carried in `Context`) is the only seam the model
touches. Native: it pushes into the in-process `ChannelHub`. Cloudflare: a
suspending `host_broadcast` (called from the request/queue isolate, where JSPI
works, never the DO) RPCs the channel's Durable Object, which fans out.

## No ambient request: three origination points

Broadcast-time rendering works with no request (the renderer is data-in/bytes-out).
All three origins work on native and Cloudflare:

| Origin | How | Example |
|---|---|---|
| Request handler | `request.context.broadcaster` after a save | `/posts/broadcast`, `/broadcast-now` |
| Job | the consumer's `Context` carries the broadcaster | `/broadcast-job` → drainer / queue consumer |
| Channel handler | `context.broadcast(to:_:)` records a cross-channel effect | `announce:` → lobby fans out to `posts` |

The job origin is the furthest from a request; the channel-handler origin records
cross-channel broadcasts the adapter applies after the handler (native via the hub;
the DO RPCs the target DO).

## Payload-agnostic fan-out

One broadcast emits both a Plume stream fragment (browser subscribers) and a typed
JSON payload (native/API subscribers); each subscriber receives only its kind.

## Signed subscriptions (mandatory)

Broadcasting makes channel authorization a real attack surface: a client must not
subscribe to an arbitrary channel and receive another entity's broadcasts. The
server mints a **channel-scoped, signed token** (`ChannelToken.mint`, HMAC-SHA256
with the signing secret); the channel verifies it at subscribe and **rejects
unsigned / forged / expired / wrong-channel** tokens with a **timing-safe**
comparison (`constantTimeEqual`). The channel id is folded into the signed message
(not the token string), so a token for channel A fails against B.

- Wire: `hex(subject) "." expirySeconds "." hex(hmac)`. ASCII, compared byte-wise,
  so it verifies in the Wasm guest too.
- Native: the WebSocket upgrade rejects (close frame) without a valid `?token=`.
- Cloudflare: the DO verifies BEFORE `acceptWebSocket` via a sync
  `plumekit_channel_verify` guest export (HMAC is pure compute, no JSPI), returning
  403 on failure. Signing key from `env`; configure `CHANNEL_SIGNING_KEY`.
- Mint server-side: `GET /channel-token?room=` → a token the client presents.

Enforcement is active whenever a signing key is configured (the example configures
it). On both native and Cloudflare: valid token accepted; no-token / forged /
wrong-channel rejected.
