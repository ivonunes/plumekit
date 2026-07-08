# Real-time channels

Persistent connections that push updates to subscribed clients. This is a different
execution model from the stateless request path: long-lived, stateful,
message-driven. One platform-neutral `Channel` abstraction sits over the platform
implementations: a Cloudflare **Durable Object**, a native **long-lived actor**
(detailed below) and, through the same protocol, **AWS API Gateway WebSockets**
(DynamoDB state + `postToConnection` fan-out). See [Portability](portability.md) and
[Deploying to AWS Lambda](aws.md).

## Two implementations, one abstraction

**Cloudflare DO + hibernation.** A DO hosts its own wasm instance and
dispatches WebSocket messages into the Swift guest. State is rebuilt from DO
storage across connections, fan-out goes via `getWebSockets`, rooms shard per DO
(`idFromName`), and state survives runtime restarts.

Constraint: `WebAssembly.Suspending` (JSPI) imports
**do not instantiate in a DO isolate** (`LinkError: requires a callable`), though
they work in the request isolate. The Durable Object handles the async I/O (storage,
broadcast) in JS and hands the handler state; the handler stays synchronous and
returns effects. Correctness comes from rebuilding state from storage on each
message, so a hibernated Durable Object resumes safely.

**Native long-lived actor.** A `ChannelHub` actor holds multiple
WebSocket connections (SwiftNIO upgrade via the upgradable pipeline), fans out and
persists per-room state to disk, restoring it across a process restart. Same
handler shape as the DO.

## The `Channel` protocol

Names no platform primitive. The shape is forced by the Durable Object model: a
**synchronous, pre-loaded store** (async store access is impossible in a DO), with
effects collected and applied by the adapter.

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

`ChannelStore` is a byte-keyed snapshot tracking writes; `ChannelContext.push`
collects `(PayloadKind, bytes)`. The **same `RoomChannel` runs on both targets**,
sharded per room.

## Adapters

- **Cloudflare (`ChannelDO` in worker.mjs):** one DO per channel id; its own wasm
  instance; WebSocket Hibernation API; loads ALL DO storage into a snapshot, calls
  `plumekit_channel_event` (decode → run `Channel` → encode writes+pushes), then
  applies (storage.put + broadcast). The snapshot/effects wire is **little-endian**
  to match `WireFormat`.
- **Native (`ChannelHub`):** a long-lived actor, sharded by room, loading the room
  snapshot from disk and persisting it back; drives the same `Channel`.

There is never a single global coordinator; both shard per entity.

## Payload-agnostic delivery

A subscriber declares its kind at connect (`?kind=payload`, default `fragment`).
The channel pushes both an HTML fragment and a typed JSON payload; the adapter
delivers each push only to subscribers of the matching kind. From one push pair, a
fragment subscriber gets `<li>msg#1: hello</li>` and a payload subscriber gets
`{"n":1,"text":"hello"}`. (Cloudflare uses `serializeAttachment` so the kind
survives hibernation.)

## SSE (one-way)

`GET /sse?room=` streams a `text/event-stream` response, subscribing to the hub and
emitting each push as a `data:` event. Simpler than WebSockets, no DO needed. An
SSE client receives the same fragments a WebSocket subscriber would.

## Reconnection contract

A reconnecting client sends `resync:<lastSeq>`; the channel replies with the
current sequence and how many messages were missed, so the client can refetch. The
framework carries the control message; the channel implements the policy
(target-agnostic). After two messages, `resync:0` →
`{"type":"resync","current":2,"missed":2}`.

## Hibernation/restart discipline

Never trust guest/in-memory state across messages on either target. Cloudflare:
DO storage + Hibernation API + constructor re-run. Native: disk persistence +
restore. On both, channel state (e.g. the count above) survives a restart.
