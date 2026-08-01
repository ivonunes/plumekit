# Real-time channels

Sometimes a page needs to change the moment something happens elsewhere: a chat message arrives, a counter ticks, another user saves a record. A channel is a persistent connection that pushes updates to subscribed clients. It is a different execution model from the stateless request path: long-lived, stateful and message-driven.

You write one platform-neutral `Channel` and an adapter runs it on each target. The adapters are a Cloudflare **Durable Object**, a native **long-lived actor** and, through the same protocol, **AWS API Gateway WebSockets** (DynamoDB state with `postToConnection` fan-out). See [Portability](portability.md) and [Deploying to AWS Lambda](aws.md).

## The `Channel` protocol

Your channel code should not know or care which platform it runs on, so `Channel` names no platform primitive. Its shape follows the most constrained host, the Durable Object: the store is a **synchronous, pre-loaded snapshot** (the Wasm guest cannot make async store calls inside a Durable Object), and every write and push is collected as an effect that the adapter applies after your handler returns.

A minimal channel reads the store, updates it and pushes to subscribers:

```swift
final class RoomChannel: Channel {
    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        let n = (context.store.int("count") ?? 0) + 1     // store pre-loaded by the adapter
        context.store.setInt("count", n)                  // writes applied (persisted) after
        context.push(htmlFragment, kind: .fragment)       // delivered to browser subscribers
        context.push(jsonPayload, kind: .payload)         // delivered to native/API subscribers
    }
}
```

`ChannelStore` is a byte-keyed snapshot that tracks writes; `ChannelContext.push` collects `(PayloadKind, bytes)` pairs. The same `RoomChannel` runs on every target, sharded per room.

## Two implementations, one abstraction

### Cloudflare: a Durable Object with hibernation

On Cloudflare each channel lives in a Durable Object that hosts its own Wasm instance and dispatches WebSocket messages into the Swift guest. State is rebuilt from Durable Object storage across connections, fan-out goes via `getWebSockets`, rooms shard per Durable Object (`idFromName`) and state survives runtime restarts.

One platform constraint shapes the whole design: `WebAssembly.Suspending` (JSPI) imports work in the request isolate but do not instantiate in a Durable Object isolate (`LinkError: requires a callable`). So the Durable Object handles the async I/O (storage, broadcast) in JavaScript and hands your handler its state; the handler stays synchronous and returns effects. Because state is rebuilt from storage on each message, a hibernated Durable Object resumes safely.

### Native: a long-lived actor

On the native server a `ChannelHub` actor holds multiple WebSocket connections (a SwiftNIO upgrade via the upgradable pipeline), fans out and persists per-room state to disk, restoring it across a process restart. Your handler has the same shape as on the Durable Object.

## Adapters

On Cloudflare the adapter is `ChannelDO` in worker.mjs: one Durable Object per channel id, each with its own Wasm instance, using the WebSocket Hibernation API. For each event it loads the Durable Object's entire storage into a snapshot, calls the `plumekit_channel_event` guest export (which decodes the snapshot, runs your `Channel` and encodes the writes and pushes), then applies the effects with `storage.put` and a broadcast.

On native the adapter is the `ChannelHub` actor, sharded by room: it loads the room snapshot from disk, drives the same `Channel` and persists the snapshot back.

There is never a single global coordinator; both adapters shard per entity.

> **Note:** The snapshot and effects cross the JavaScript/Wasm boundary in a little-endian binary format matching the framework's `WireFormat`. You never touch it; it is why `ChannelStore` keys and values are bytes rather than platform types.

## Payload-agnostic delivery

Different subscribers want different shapes of the same update: a browser wants HTML to insert, an API client wants JSON. A subscriber declares its kind at connect (`?kind=payload`, default `fragment`). The channel pushes both an HTML fragment and a typed JSON payload; the adapter delivers each push only to subscribers of the matching kind. From one push pair, a fragment subscriber gets `<li>msg#1: hello</li>` and a payload subscriber gets `{"n":1,"text":"hello"}`. Cloudflare stores the kind with `serializeAttachment`, so it survives hibernation.

## Server-sent events

For one-way updates you do not need a WebSocket. `GET /sse?room=` streams a `text/event-stream` response, subscribing to the hub and emitting each push as a `data:` event. It is simpler than a WebSocket, and on Cloudflare no Durable Object is needed. An SSE client receives the same fragments a WebSocket subscriber would.

## Reconnection contract

A client that reconnects after a network drop needs to know what it missed. The convention is a control message: the client sends `resync:<lastSeq>` and the channel replies with the current sequence and how many messages were missed, so the client can refetch. For example, a channel that has processed two messages answers `resync:0` with `{"type":"resync","current":2,"missed":2}`.

The framework carries the control message like any other; your channel implements the policy. That keeps the contract target-agnostic.

## Hibernation and restart discipline

Never trust guest or in-memory state across messages, on either target. Cloudflare relies on Durable Object storage, the Hibernation API and the constructor re-running; native relies on disk persistence and restore. On both, channel state (the count in the example above) survives a restart.

See [Model-driven broadcasting](broadcasting.md) to push into a channel from outside it, with no socket in scope.
