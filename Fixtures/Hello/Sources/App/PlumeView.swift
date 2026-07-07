import PlumeCore
import PlumeRuntime

// App-level sugar: turn a rendered Plume `HTML` buffer into a PlumeKit `Response`.
// Lives in the app (which imports both PlumeCore and PlumeRuntime) so the framework
// core stays decoupled from any particular view engine.
extension Response {
    static func view(_ html: HTML, status: Int = 200) -> Response {
        .html(bytes: html.bytes, status: status)
    }

    // A Plume stream envelope response (targeted update). The @navigation client
    // runtime detects `<plume-stream>` in the body and applies it. Bridged here so
    // the framework core stays decoupled from Plume.
    static func stream(_ envelope: StreamEnvelope, status: Int = 200) -> Response {
        .html(bytes: envelope.bytes, status: status)
    }
}
