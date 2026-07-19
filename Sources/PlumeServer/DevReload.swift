import Foundation
import PlumeCore

// Browser live-reload for `plumekit dev` (and any server run with
// PLUMEKIT_ENV=development — deployed servers never set it, so none of this
// exists in production responses).
//
// Mechanism: every HTML page gets a tiny inline poller that fetches this
// process's random boot id once a second. `plumekit dev` swaps in a freshly
// built server only when the build succeeds; the swap changes the boot id, the
// poller notices and reloads the page. While the old server is still serving a
// broken build's compile errors in the terminal, the id is unchanged and the
// browser just keeps the last working page.
enum DevReload {
    /// This process's identity — changes on every server start.
    static let bootID: String = {
        var id = ""
        for _ in 0..<16 { id += String(UInt8.random(in: 0...15), radix: 16) }
        return id
    }()

    /// The polling endpoint's path. Namespaced so it can't collide with app routes.
    static let path = "/plumekit.dev.reload"

    /// ES5 on purpose (the repo's browser-code rule): no arrows, no fetch.
    private static let script = """
    <script>(function(){var known=null;function tick(){var x=new XMLHttpRequest();\
    x.open("GET","\(path)",true);x.onload=function(){if(x.status===200){\
    if(known===null){known=x.responseText}else if(x.responseText!==known){location.reload();return}}\
    setTimeout(tick,1000)};x.onerror=function(){setTimeout(tick,500)};x.send()}tick()})();</script>
    """

    /// Inject the poller into a buffered HTML response (before `</body>` when
    /// present, appended otherwise). Anything else passes through untouched.
    static func inject(into response: Response) -> Response {
        guard response.status == 200,
              let contentType = response.headers.first("content-type"),
              utf8HasPrefix(contentType, "text/html"),
              !response.body.isEmpty else { return response }
        var out = response
        let scriptBytes = Array(script.utf8)
        if let at = closingBodyIndex(in: response.body) {
            out.body.insert(contentsOf: scriptBytes, at: at)
        } else {
            out.body.append(contentsOf: scriptBytes)
        }
        return out
    }

    /// Byte-scan (from the end — it's the last tag) for `</body>`, case-insensitive.
    private static func closingBodyIndex(in bytes: [UInt8]) -> Int? {
        let needle: [UInt8] = [0x3C, 0x2F, 0x62, 0x6F, 0x64, 0x79]   // "</body"
        guard bytes.count >= needle.count else { return nil }
        func lower(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 32 : b }
        var i = bytes.count - needle.count
        while i >= 0 {
            var match = true
            for j in 0..<needle.count where lower(bytes[i + j]) != needle[j] {
                match = false
                break
            }
            if match { return i }
            i -= 1
        }
        return nil
    }
}
