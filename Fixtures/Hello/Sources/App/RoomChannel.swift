import PlumeCore
import PlumeRuntime

// A real-time channel — platform-neutral app code that names NO platform type. The
// SAME RoomChannel runs inside a Cloudflare Durable Object and the native
// long-lived actor. State is read/written through the (pre-loaded) channel store;
// `push` fans out to subscribers. The adapter persists the writes and delivers the
// pushes — the app doesn't know or care which target it's on.
final class RoomChannel: Channel {
    init() {}

    func onMessage(_ message: [UInt8], _ context: ChannelContext) async throws {
        // Reconnection contract: a client that reconnects sends `resync:<lastSeq>`;
        // the channel replies with the current sequence + how many it missed, so the
        // client can refetch. (Byte-wise prefix — this runs in the wasm guest too.)
        if let lastSeq = parseResync(message) {
            let current = context.store.int("count") ?? 0
            let directive = JSONValue.object([
                ("type", .string("resync")),
                ("current", .int(Int64(current))),
                ("missed", .int(Int64(max(0, current - lastSeq)))),
            ])
            context.push(directive.serialize(), kind: .payload)
            return
        }

        // Origination point #3: a channel handler broadcasts to ANOTHER channel.
        // `announce:<text>` here fans a rendered fragment out to the "posts" channel.
        if let announcement = parseAnnounce(message) {
            var envelope = StreamEnvelope()
            envelope.add(.prepend, target: "posts") { html in
                html.literal("<li>announce: ")
                html.text(decodeUTF8(announcement))
                html.literal("</li>")
            }
            context.broadcast(to: ChannelID("posts"),
                              [ChannelPush(kind: .fragment, bytes: envelope.bytes)])
            return
        }

        let count = (context.store.int("count") ?? 0) + 1
        context.store.setInt("count", count)

        // Payload-agnostic delivery (Addendum A): browsers get an HTML fragment,
        // native/API subscribers get a typed JSON payload — one channel, two kinds.
        var fragment = Array("<li>msg#\(count): ".utf8)
        fragment.append(contentsOf: message)
        fragment.append(contentsOf: Array("</li>".utf8))
        context.push(fragment, kind: .fragment)

        let payload = JSONValue.object([
            ("n", .int(Int64(count))),
            ("text", .string(decodeUTF8(message))),
        ])
        context.push(payload.serialize(), kind: .payload)
    }
}

// Byte-wise `resync:<int>` parse (no String.hasPrefix; it doesn't link under Embedded).
private func parseResync(_ message: [UInt8]) -> Int? {
    let prefix = Array("resync:".utf8)
    guard message.count > prefix.count, Array(message[0..<prefix.count]) == prefix else { return nil }
    return Int(decodeUTF8(Array(message[prefix.count...])))
}

// Byte-wise `announce:<text>` parse → the text bytes (or nil).
private func parseAnnounce(_ message: [UInt8]) -> [UInt8]? {
    let prefix = Array("announce:".utf8)
    guard message.count > prefix.count, Array(message[0..<prefix.count]) == prefix else { return nil }
    return Array(message[prefix.count...])
}

public func buildChannel() -> some Channel { RoomChannel() }
