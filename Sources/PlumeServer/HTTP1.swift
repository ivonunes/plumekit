import PlumeCore

// Minimal HTTP/1.1 request parsing and response serialization for the native
// adapter. Kept dependency-free (no Foundation, no SwiftNIO) and operating on
// `[UInt8]` so the same byte-oriented mindset as the core carries over. This is
// the only place that speaks wire-format HTTP text — the Wasm path uses the
// compact binary ABI instead.

/// The parsed start-line + headers of a request, plus how many bytes they
/// occupied and the declared body length (so the caller knows how much body to
/// read off the socket).
struct RequestHead {
    let method: HTTPMethod
    let path: String
    let query: String
    let headers: Headers
    let contentLength: Int
    let headerByteCount: Int
}

/// Index of the first byte of the `\r\n\r\n` head/body separator, or nil if the
/// accumulated bytes don't yet contain a complete header block.
func indexOfHeaderTerminator(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    var i = 0
    while i <= bytes.count - 4 {
        if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
            return i
        }
        i += 1
    }
    return nil
}

/// Parse the request head from `bytes`. Returns nil if the head is incomplete or
/// malformed; the caller keeps reading and retries.
func parseRequestHead(_ bytes: [UInt8]) -> RequestHead? {
    guard let term = indexOfHeaderTerminator(bytes) else { return nil }

    // Split the header block into lines on raw LF bytes, trimming a trailing CR.
    // We split BYTES, not a decoded String: Swift models "\r\n" as a single
    // grapheme cluster, so `String.split(separator: "\n")` would never match a
    // CRLF-delimited HTTP head.
    var lines: [String] = []
    var current: [UInt8] = []
    var i = 0
    while i < term {
        let byte = bytes[i]
        if byte == 10 {  // LF
            if current.last == 13 { current.removeLast() }  // strip CR
            lines.append(decodeUTF8(current))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(byte)
        }
        i += 1
    }
    if current.last == 13 { current.removeLast() }
    lines.append(decodeUTF8(current))

    guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }

    // Request line: METHOD SP request-target SP HTTP-version
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    guard let method = HTTPMethod(name: String(parts[0])) else { return nil }

    let target = String(parts[1])
    let (path, query) = splitTarget(target)

    var headers = Headers()
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        while value.first == " " { value.removeFirst() }
        headers.add(name, value)
    }

    var contentLength = 0
    if let value = headers.first("content-length"), let n = Int(value), n >= 0 {
        contentLength = n
    }

    return RequestHead(
        method: method,
        path: path,
        query: query,
        headers: headers,
        contentLength: contentLength,
        headerByteCount: term + 4
    )
}

/// Split a request target into (path, query) on the first `?`.
private func splitTarget(_ target: String) -> (String, String) {
    if let q = target.firstIndex(of: "?") {
        let path = String(target[target.startIndex..<q])
        let query = String(target[target.index(after: q)...])
        return (path, query)
    }
    return (target, "")
}

/// Serialize a `Response` to HTTP/1.1 wire bytes. Always sets an accurate
/// `Content-Length` and closes the connection (v0 uses one request per socket).
func serializeResponse(_ response: Response) -> [UInt8] {
    var out: [UInt8] = []
    out.append(contentsOf: encodeUTF8("HTTP/1.1 \(response.status) \(response.reasonPhrase)\r\n"))

    var headers = response.headers
    headers.set("content-length", String(response.body.count))
    headers.set("connection", "close")
    for field in headers.fields {
        out.append(contentsOf: encodeUTF8("\(field.name): \(field.value)\r\n"))
    }
    out.append(contentsOf: encodeUTF8("\r\n"))
    out.append(contentsOf: response.body)
    return out
}
