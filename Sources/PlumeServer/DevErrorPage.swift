import Foundation
import PlumeCore

// The development error page. When a handler throws under `plumekit serve`/`dev`
// (PLUMEKIT_ENV=development), the native server renders the error with the request's
// full context instead of an opaque 500 — the error type and description, the request
// (method, path, query, headers, body preview), and the app's route table.
//
// Native-only by design: the embedded-Wasm guest can't stringify an arbitrary
// `any Error` (no reflection), and production keeps the clean 500 regardless.
enum DevErrorPage {
    static func response(error: any Error, request: Request, routes: [(method: String, path: String)]) -> Response {
        let errorType = escape(String(describing: type(of: error)))
        let message = escape(String(describing: error))

        var headerRows = ""
        for field in request.headers.fields {
            headerRows += "<tr><td>\(escape(field.name))</td><td>\(escape(field.value))</td></tr>"
        }

        var routeRows = ""
        for route in routes {
            routeRows += "<tr><td class=\"m\">\(escape(route.method))</td><td>\(escape(route.path))</td></tr>"
        }

        // A short, printable body preview — form posts and JSON are what you debug most.
        var bodySection = ""
        if !request.body.isEmpty {
            let preview = String(decoding: request.body.prefix(2048), as: UTF8.self)
            let suffix = request.body.count > 2048 ? "\n… (\(request.body.count) bytes total)" : ""
            bodySection = """
            <h2>Request body</h2>
            <pre class="panel">\(escape(preview + suffix))</pre>
            """
        }

        let query = request.query.isEmpty ? "" : "?\(escape(request.query))"
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(errorType) — PlumeKit</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin: 0; background: #0b1018; color: #e6ebf2; font: 15px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
          main { max-width: 60rem; margin: 0 auto; padding: 3rem 1.5rem 4rem; }
          .eyebrow { color: #f87171; font-size: .78rem; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; margin: 0 0 .75rem; }
          h1 { margin: 0 0 .35rem; font-size: 1.9rem; line-height: 1.25; }
          h1 .grad { background: linear-gradient(90deg, #f87171, #fb923c); -webkit-background-clip: text; background-clip: text; color: transparent; }
          .req { color: #8b95a7; margin: 0 0 2rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .95rem; }
          .req .m { color: #60a5fa; font-weight: 700; }
          h2 { font-size: .8rem; letter-spacing: .1em; text-transform: uppercase; color: #8b95a7; margin: 2.2rem 0 .6rem; }
          .panel { background: #111827; border: 1px solid #1f2937; border-radius: 10px; padding: 1rem 1.15rem; overflow-x: auto; }
          pre.panel { margin: 0; font: .9rem/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; word-break: break-word; }
          table { width: 100%; border-collapse: collapse; font-size: .88rem; table-layout: fixed; }
          td { padding: .4rem .6rem; border-top: 1px solid #1f2937; vertical-align: top; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-word; }
          tr:first-child td { border-top: 0; }
          td:first-child { color: #8b95a7; width: 13rem; padding-right: 1.2rem; }
          td.m { color: #60a5fa; font-weight: 700; }
          .note { margin-top: 2.5rem; color: #66707f; font-size: .82rem; }
          .note code { color: #8b95a7; }
        </style>
        </head>
        <body>
        <main>
          <p class="eyebrow">Unhandled error</p>
          <h1><span class="grad">\(errorType)</span></h1>
          <p class="req"><span class="m">\(escape(request.method.name))</span> \(escape(request.path))\(query)</p>
          <h2>Error</h2>
          <pre class="panel">\(message)</pre>
          \(bodySection)
          <h2>Request headers</h2>
          <div class="panel"><table>\(headerRows)</table></div>
          <h2>Routes</h2>
          <div class="panel"><table>\(routeRows)</table></div>
          <p class="note">PlumeKit development error page — shown because <code>PLUMEKIT_ENV=development</code>.
          In production this request returns a plain 500.</p>
        </main>
        </body>
        </html>
        """
        var headers = Headers()
        headers.add("content-type", "text/html; charset=utf-8")
        return Response(status: 500, headers: headers, body: Array(html.utf8))
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
