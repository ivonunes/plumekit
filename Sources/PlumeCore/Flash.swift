// Flash messages — the one-time notice shown after a redirect ("Post created").
//
// The message rides a short-lived cookie instead of server-side session state, so it
// works identically on every target (native, Workers, Lambda) with no storage
// round-trip. The framework clears it automatically after the next request renders
// it (see `Application.handleThrowing`), so it shows exactly once.
//
//     // In the handler that redirects:
//     return .redirect(to: "/posts").flash("Post created")
//     return .redirect(to: "/posts").flash("Payment failed", kind: Flash.error)
//
//     // In the handler that renders the next page:
//     let flash = request.flash        // FlashMessage? — pass into your view
//
// Flash content is client-visible display text (the cookie is yours to read in the
// browser too) — never put secrets in it. Plume escapes it on render like any output.

/// A one-time message carried across a redirect.
public struct FlashMessage: Sendable {
    /// One of the `Flash` kind constants by convention (`notice`, `success`, …) —
    /// typically used as a CSS class on the banner.
    public let kind: String
    public let message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum Flash {
    public static let notice = "notice"
    public static let success = "success"
    public static let error = "error"
    public static let warning = "warning"

    public static let cookieName = "plumekit_flash"

    /// The `Set-Cookie` value carrying a flash. One minute is plenty — the very next
    /// page view consumes and clears it; the Max-Age only bounds abandoned redirects.
    static func setCookie(kind: String, message: String) -> String {
        cookieName + "=" + encode(kind) + "." + encode(message)
            + "; Path=/; SameSite=Lax; HttpOnly; Max-Age=60"
    }

    static var clearCookie: String {
        cookieName + "=; Path=/; HttpOnly; Max-Age=0"
    }

    /// Parse a cookie payload (`<kind>.<message>`, both percent-encoded).
    static func parse(_ payload: String) -> FlashMessage? {
        guard !payload.isEmpty else { return nil }
        let bytes = Array(payload.utf8)
        guard let dot = bytes.firstIndex(of: 0x2E) else { return nil }   // '.'
        let kind = decode(Array(bytes[..<dot]))
        let message = decode(Array(bytes[(dot + 1)...]))
        guard !message.isEmpty else { return nil }
        return FlashMessage(kind: kind.isEmpty ? notice : kind, message: message)
    }

    // Byte-wise percent codec (cookie-safe, no Unicode-aware String ops — the same
    // discipline as form decoding, so it links in the embedded guest).
    static func encode(_ text: String) -> String {
        var out: [UInt8] = []
        for byte in Array(text.utf8) {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F, 0x7E:   // 0-9 A-Z a-z - _ ~
                out.append(byte)
            default:
                out.append(0x25)   // '%'
                out.append(hexDigit(byte >> 4))
                out.append(hexDigit(byte & 0x0F))
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo)); i += 3
            } else {
                out.append(bytes[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? 0x30 + nibble : 0x41 + nibble - 10
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }
}

extension Response {
    /// Attach a one-time flash message, shown by the next page view and then cleared.
    /// Chain it onto a redirect: `.redirect(to: "/posts").flash("Post created")`.
    public func flash(_ message: String, kind: String = Flash.notice) -> Response {
        settingCookie(Flash.setCookie(kind: kind, message: message))
    }
}

extension Request {
    /// The flash message set by the previous request, if any. Pass it into your view;
    /// the framework clears the cookie automatically once this request completes.
    public var flash: FlashMessage? {
        guard let payload = extractCookie(self, name: Flash.cookieName) else { return nil }
        return Flash.parse(payload)
    }
}
