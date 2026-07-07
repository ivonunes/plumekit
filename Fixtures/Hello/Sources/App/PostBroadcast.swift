import PlumeCore
import PlumeORM
import PlumeRuntime

// A model declares that its changes broadcast to a channel. It names a
// ChannelID + the pushes (a fragment rendered with NO request + a typed payload) —
// no socket, no DO, no platform type. `broadcast(post, via:)` resolves the channel
// and fans both kinds out. The SAME conformance drives native and Cloudflare.
extension Post: Broadcastable {
    public static func broadcastChannel(for model: Post) -> ChannelID {
        ChannelID("posts")
    }

    public static func broadcastPushes(for model: Post) -> [ChannelPush] {
        // A new post PREPENDS a card to the "posts" list (a stream action on
        // broadcast). Rendered with no request — data in, bytes out.
        var envelope = StreamEnvelope()
        envelope.add(.prepend, target: "posts") { html in
            html.literal("<li data-id=\"")
            html.text(model.id)
            html.literal("\">")
            html.text(model.title)
            html.literal("</li>")
        }
        // The typed payload for native/API subscribers.
        let payload = JSONValue.object([
            ("id", .int(Int64(model.id))),
            ("title", .string(model.title)),
        ]).serialize()

        return [
            ChannelPush(kind: .fragment, bytes: envelope.bytes),
            ChannelPush(kind: .payload, bytes: payload),
        ]
    }
}
