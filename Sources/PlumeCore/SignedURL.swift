// Signed URLs — links that authenticate themselves, for routes that must work
// without a session: unsubscribe links, file downloads, magic invites. The URL
// carries an HMAC of its own path + query (+ optional expiry); tampering with any
// part of it, or using it past its expiry, fails verification.
//
//     // Issue (e.g. into an email):
//     let url = SignedURL.sign("/unsubscribe?user=42", key: key,
//                              expiresAt: Int64(nowSeconds + 86_400))
//
//     // Verify in the handler:
//     guard SignedURL.verify(request, key: key, nowEpochSeconds: now) else {
//         return .status(403)
//     }
//
// Byte-wise HMAC-SHA256 with constant-time comparison; Embedded-clean on every target.

public enum SignedURL {
    static let signatureParameter = "sig"
    static let expiryParameter = "sig_exp"

    /// Sign `pathAndQuery` (e.g. `/unsubscribe?user=42`). Appends `sig` (and
    /// `sig_exp` when an expiry is given) to the query.
    public static func sign(_ pathAndQuery: String, key: [UInt8], expiresAt: Int64? = nil) -> String {
        var url = pathAndQuery
        if let expiresAt {
            url += (url.contains("?") ? "&" : "?") + expiryParameter + "=" + String(expiresAt)
        }
        let signature = hexEncode(hmacSHA256(key: key, message: Array(url.utf8)))
        return url + (url.contains("?") ? "&" : "?") + signatureParameter + "=" + signature
    }

    /// Verify a request against the signature its URL carries. Checks the HMAC over
    /// the path + query (minus `sig` itself) and, when present, the expiry.
    public static func verify(_ request: Request, key: [UInt8], nowEpochSeconds: Int64) -> Bool {
        // Take the query apart: everything except `sig` is covered by the signature.
        var covered: [String] = []
        var signature = ""
        var expiry: Int64?
        for pair in splitQuery(request.query) {
            if let value = value(of: signatureParameter, in: pair) {
                signature = value
            } else {
                if let value = value(of: expiryParameter, in: pair) {
                    expiry = parseInt64(value)
                }
                covered.append(pair)
            }
        }
        guard !signature.isEmpty, let provided = hexDecode(Array(signature.utf8)) else { return false }
        if let expiry, expiry < nowEpochSeconds { return false }

        var url = request.path
        if !covered.isEmpty { url += "?" + joinQuery(covered) }
        let expected = hmacSHA256(key: key, message: Array(url.utf8))
        return constantTimeEqual(expected, provided)
    }

    // Byte-wise query helpers (order-preserving — the signature covers the query
    // exactly as sent).
    private static func splitQuery(_ query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        var parts: [String] = []
        var current: [UInt8] = []
        for byte in Array(query.utf8) {
            if byte == 0x26 {   // '&'
                parts.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(byte)
            }
        }
        parts.append(String(decoding: current, as: UTF8.self))
        return parts
    }

    private static func joinQuery(_ parts: [String]) -> String {
        var out = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { out += "&" }
            out += part
        }
        return out
    }

    private static func value(of name: String, in pair: String) -> String? {
        let prefix = name + "="
        guard asciiHasPrefix(pair, prefix) else { return nil }
        return String(pair.dropFirst(prefix.count))
    }

    private static func parseInt64(_ text: String) -> Int64 {
        // Strict digits-only parse with overflow saturation: this runs on the raw
        // query BEFORE the signature check, so it must never trap on hostile input.
        var value: Int64 = 0
        for byte in Array(text.utf8) {
            guard byte >= 0x30, byte <= 0x39 else { return Int64.max }   // non-digit → never valid
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            if overflow1 { return Int64.max }
            let (sum, overflow2) = shifted.addingReportingOverflow(Int64(byte - 0x30))
            if overflow2 { return Int64.max }
            value = sum
        }
        return value
    }
}
