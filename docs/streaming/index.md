# Fragments and the stream envelope

Plume render functions are **context-independent**: a compiled component renders a
single region standalone: data in, bytes out, with no ambient request and no
host. That makes a render function usable as a *fragment* producer, and fragments
are what stream updates carry.

```swift
// A fragment is just a render into a fresh buffer.
let bytes = Plume.fragment { out in postRow(post: post, into: &out) }
```

## The stream envelope

A **stream envelope** is Plume's documented wire format for delivering fragment
updates to a live page, the Hotwire/Turbo-Streams equivalent. Plume *defines and
encodes* the format and nothing more: it does not know or care how an envelope is
produced or transported. A form response, a WebSocket broadcast, an SSE event:
all of that is someone else's concern. The client runtime applies envelopes via
`Plume.apply(envelope)`.

An envelope is a sequence of operations, each a `(action, target, fragment)`
tuple, encoded as one `<plume-stream>` element per operation:

```html
<plume-stream action="append" target="messages"><template>
  <li id="message_19">…</li>
</template></plume-stream>
<plume-stream action="remove" target="flash"></plume-stream>
```

- `target` is the `id` of the element the operation acts on; it is attribute-escaped.
- The fragment is already-rendered, already-escaped HTML and rides inert inside
  `<template>`, so it parses without executing or rendering until applied.
- `remove` carries no fragment.
- Elements concatenate freely, so an envelope streams over any text transport.

### Actions

The vocabulary is copied from Turbo Streams exactly:

| action    | effect on the target                                   |
|-----------|--------------------------------------------------------|
| `append`  | insert the fragment as the target's last child         |
| `prepend` | insert the fragment as the target's first child        |
| `replace` | replace the target element itself with the fragment    |
| `update`  | replace the target's children with the fragment        |
| `remove`  | remove the target element (no fragment)                |
| `before`  | insert the fragment before the target                  |
| `after`   | insert the fragment after the target                   |
| `morph`   | morph the target in place toward the fragment (DOM diff)|

### Encoding

Encoding works in the Wasm guest too, so envelopes can be built at
request time:

```swift
var envelope = StreamEnvelope()
envelope.add(.append, target: "messages") { out in
    messageRow(message: message, into: &out)   // a compiled render function
}
envelope.remove(target: "flash")
send(envelope.bytes)   // hand the bytes to any transport; Plume stops here
```

`StreamEnvelope.add(_:target:fragment:)` takes already-rendered fragment bytes;
the closure overload renders inline. `StreamEnvelope.bytes` is the encoded
envelope.

## The seam

Everything a server-side framework needs is behind two things: render functions
that emit fragments, and this envelope format plus the runtime's `apply`/`visit`
API. Plume never sees the transport.
