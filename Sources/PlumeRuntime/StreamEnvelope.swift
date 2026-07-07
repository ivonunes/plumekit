//
//  StreamEnvelope.swift
//  PlumeRuntime
//
//  Plume's documented wire format for streaming HTML fragment updates — the
//  Hotwire/Turbo-Streams equivalent. An envelope is a sequence of operations,
//  each a (action, target-id, fragment) tuple. Plume defines and encodes the
//  format; it knows NOTHING about how an envelope is produced or transported
//  (a form response, a WebSocket broadcast, an SSE event — all someone else's
//  problem). The client runtime's `Plume.apply(envelope)` consumes it.
//
//  Wire format (one element per operation, concatenable):
//
//      <plume-stream action="append" target="messages"><template>…fragment…</template></plume-stream>
//      <plume-stream action="remove" target="flash"></plume-stream>
//
//  The fragment is already-rendered, already-escaped HTML (produced by a compiled
//  render function); it rides inert inside <template> so it parses without
//  executing or rendering until applied. `remove` carries no fragment.
//
//  Encoding is Embedded-Swift-clean: byte-wise over a [UInt8] buffer, so a guest
//  can build envelopes at request time.
//

/// The action vocabulary, copied from Turbo Streams exactly.
public enum StreamAction {
    case append    // insert fragment as the target's last child
    case prepend   // insert fragment as the target's first child
    case replace   // replace the target element itself with the fragment
    case update    // replace the target's children with the fragment
    case remove    // remove the target element (no fragment)
    case before    // insert fragment before the target
    case after     // insert fragment after the target
    case morph     // morph the target in place toward the fragment (DOM diff)

    /// The `action="…"` token written to the wire. A `StaticString` switch is
    /// used instead of an enum raw value to stay Embedded-clean.
    public var wireName: StaticString {
        switch self {
        case .append: return "append"
        case .prepend: return "prepend"
        case .replace: return "replace"
        case .update: return "update"
        case .remove: return "remove"
        case .before: return "before"
        case .after: return "after"
        case .morph: return "morph"
        }
    }

    /// `remove` targets an existing element and needs no payload.
    public var carriesFragment: Bool {
        switch self {
        case .remove: return false
        default: return true
        }
    }
}

/// Accumulates stream operations into wire-format bytes.
public struct StreamEnvelope {
    private var buffer: HTML

    public init() {
        buffer = HTML()
    }

    /// The encoded envelope bytes, ready to hand to any transport.
    public var bytes: [UInt8] { buffer.bytes }

    /// Appends one operation whose payload is already-rendered fragment bytes.
    public mutating func add(_ action: StreamAction, target: String, fragment: [UInt8]) {
        buffer.literal("<plume-stream action=\"")
        buffer.literal(action.wireName)
        buffer.literal("\" target=\"")
        buffer.text(target)  // escapes & < > " ' for the attribute value
        buffer.literal("\">")
        if action.carriesFragment {
            buffer.literal("<template>")
            buffer.append(fragment)
            buffer.literal("</template>")
        }
        buffer.literal("</plume-stream>")
    }

    /// Appends one operation, rendering its fragment inline.
    public mutating func add(
        _ action: StreamAction, target: String, _ render: (inout HTML) -> Void
    ) {
        var fragment = HTML()
        render(&fragment)
        add(action, target: target, fragment: fragment.bytes)
    }

    /// Appends a `remove` operation (no fragment).
    public mutating func remove(target: String) {
        add(.remove, target: target, fragment: [])
    }
}
