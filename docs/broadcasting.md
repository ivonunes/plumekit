# Model-driven broadcasting

Sometimes an update starts in your data, not in a socket handler: a model is saved and every subscriber should see it. Model-driven broadcasting renders a fragment from a model change and fans it out over a channel to subscribers, with no request in scope. It connects the model layer and the renderer to the real-time layer, and adds the security piece broadcasting makes mandatory: **signed subscriptions**. Everything routes through the `Channel` abstraction and the `SecretProvider` only, never a platform type, so it works identically on the native server and Cloudflare.

## Originating a broadcast

A model declares its broadcast target and payloads by conforming to `Broadcastable`: name a `ChannelID` and build the pushes, a fragment rendered with no request plus a typed payload. There is no socket handling and no Durable Object code:

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

`broadcast(post, via:)` sends the model's pushes to its channel; nothing in the call names a platform.

## The broadcaster seam

The `Broadcaster` capability (carried in `Context`) is the only seam the model touches. On native it pushes into the in-process `ChannelHub`. On Cloudflare a suspending `host_broadcast` import RPCs the channel's Durable Object, which fans out; the import is called from the request or queue isolate, where JSPI works, never from the Durable Object.

## Three origination points

Broadcast-time rendering works with no request, because the renderer is data-in, bytes-out. A broadcast can start from a request handler, from a job or from another channel's handler, and all three work on native and Cloudflare:

| Origin | How | Example |
|---|---|---|
| Request handler | `request.context.broadcaster` after a save | a `POST /posts` handler saves a post, then broadcasts it |
| Job | the consumer's `Context` carries the broadcaster | a queued job finishes its work and broadcasts the result |
| Channel handler | `context.broadcast(to:_:)` records a cross-channel effect | a lobby channel fans an announcement out to a `posts` channel |

The job origin is the furthest from a request. The channel-handler origin records cross-channel broadcasts the adapter applies after the handler returns: native fans them out via the hub, and the Durable Object RPCs the target Durable Object.

## Payload-agnostic fan-out

One broadcast emits both a Plume stream fragment (browser subscribers) and a typed JSON payload (native/API subscribers); each subscriber receives only its kind. See [Real-time channels](channels.md#payload-agnostic-delivery).

## Signed subscriptions (mandatory)

Broadcasting makes channel authorisation a real attack surface: a client must not subscribe to an arbitrary channel and receive another entity's broadcasts. So subscriptions are signed.

The server mints a channel-scoped, signed token (`ChannelToken.mint`, HMAC-SHA256 with the signing secret). The channel verifies the token at subscribe time; an unsigned, forged, expired or wrong-channel token is rejected, and the signature check is timing-safe (`constantTimeEqual`). The channel id is folded into the signed message rather than the token string, so a token minted for channel A fails against channel B.

How each piece works in practice:

- Wire format: `hex(subject) "." expirySeconds "." hex(hmac)`. All ASCII, compared byte-wise, so it verifies in the Wasm guest too.
- Native: the WebSocket upgrade rejects the connection (close frame) unless a valid `?token=` is presented.
- Cloudflare: the Durable Object verifies before `acceptWebSocket`, via a synchronous `plumekit_channel_verify` guest export (HMAC is pure compute, so no JSPI is needed), and returns 403 on failure. The signing key comes from `env`; configure `CHANNEL_SIGNING_KEY`.
- Minting: expose a server-side route (for example `GET /channel-token?room=`) that returns a token the client presents when subscribing.

Enforcement is active whenever a signing key is configured, so an app that configures one gets the full check on both targets: a valid token is accepted, and no-token, forged and wrong-channel subscriptions are rejected.
