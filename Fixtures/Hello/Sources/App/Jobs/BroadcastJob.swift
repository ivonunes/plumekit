import PlumeCore
import PlumeRuntime

// A JOB renders a fragment with NO request in scope and broadcasts it to
// a channel. This is the origination point furthest from a request — if any
// request-coupling lurked in the renderer, it would surface here. `perform` runs in
// the consumer (native drainer / Cloudflare queue consumer), reaches the
// Broadcaster on its Context, renders via Plume, and fans out fragment + payload.
struct BroadcastJob: Job {
    static let name = "broadcast"
    let room: String
    let text: String

    init(room: String, text: String) { self.room = room; self.text = text }
    init(payload: [UInt8]) {
        let parts = splitOnByte(payload, 0x7C)  // '|'
        self.room = parts.count > 0 ? decodeUTF8(parts[0]) : "lobby"
        self.text = parts.count > 1 ? decodeUTF8(parts[1]) : ""
    }
    func payload() -> [UInt8] { encodeUTF8(room + "|" + text) }

    func perform(_ context: Context) async throws {
        guard let broadcaster = context.broadcaster else { return }
        await broadcast(room: room, text: text, "job", via: broadcaster)
    }
}

// Shared render+fan-out used by every origination point (request / job / channel) —
// proving the SAME no-request render path works regardless of where it's called.
func broadcast(room: String, text: String, _ origin: String, via broadcaster: Broadcaster) async {
    // Render an HTML fragment with NO request (data in → bytes out), as a Plume
    // stream op that PREPENDS to the "messages" list.
    var envelope = StreamEnvelope()
    envelope.add(.prepend, target: "messages") { html in
        html.literal("<li>")
        html.text(origin + ": " + text)
        html.literal("</li>")
    }
    // The typed payload for native/API subscribers.
    let payload = JSONValue.object([
        ("type", .string(origin)),
        ("text", .string(text)),
    ]).serialize()

    await broadcaster.send(to: ChannelID(room), [
        ChannelPush(kind: .fragment, bytes: envelope.bytes),
        ChannelPush(kind: .payload, bytes: payload),
    ])
}
