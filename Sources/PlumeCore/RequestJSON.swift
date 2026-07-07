// Request-side JSON + content negotiation. Byte-wise throughout — no
// Unicode-aware String operations (they don't link under Embedded).
extension Request {
    /// Parse the request body as JSON, or nil if it isn't valid JSON.
    public func json() -> JSONValue? { parseJSON(body) }

    /// Whether the client's `Accept` header asks for JSON.
    public var wantsJSON: Bool {
        guard let accept = headers.first("accept") else { return false }
        return bytesContain(Array(accept.utf8), Array("application/json".utf8))
    }

    /// Whether the `Content-Type` is JSON.
    public var hasJSONBody: Bool {
        guard let type = headers.first("content-type") else { return false }
        return bytesContain(Array(type.utf8), Array("application/json".utf8))
    }
}

/// Substring search over bytes (avoids `String.contains`, which is Unicode-aware).
func bytesContain(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if haystack.count < needle.count { return false }
    var i = 0
    while i <= haystack.count - needle.count {
        var matched = true
        var j = 0
        while j < needle.count {
            if haystack[i + j] != needle[j] { matched = false; break }
            j += 1
        }
        if matched { return true }
        i += 1
    }
    return false
}
