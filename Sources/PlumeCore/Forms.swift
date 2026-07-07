import _Concurrency
import PlumeRuntime

// CSRF protection + HTTP method override, as middleware. Both are platform-
// neutral and Embedded-clean; the CSRF signing key comes from the
// SecretProvider, never a direct platform call.

// MARK: - CSRF

public enum CSRF {
    /// The form field / header carrying the token.
    public static let fieldName = "_csrf"
    public static let headerName = "x-csrf-token"
    /// The per-visitor cookie the token is bound to (signed double-submit).
    public static let cookieName = "plumekit_csrf"

    /// A fresh per-visitor value: 16 random bytes, hex.
    public static func mintValue() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        for _ in 0..<16 { bytes.append(UInt8.random(in: .min ... .max, using: &generator)) }
        return hexEncode(bytes)
    }

    /// The token a form embeds: the visitor value plus its HMAC signature. The
    /// signature stops an attacker from planting their own cookie+token pair (a
    /// valid pair requires the server secret); the value binds the token to THIS
    /// visitor's cookie, so it is unpredictable per visitor and useless if stolen
    /// from someone else's page.
    public static func token(value: String, secret: String) -> String {
        value + "." + hexEncode(hmacSHA256(key: Array(secret.utf8), message: Array(value.utf8)))
    }

    /// Timing-safe validation: the submitted token must carry a valid signature AND
    /// match the visitor's cookie value.
    public static func isValid(_ submitted: String?, cookieValue: String?, secret: String) -> Bool {
        guard let submitted, let cookieValue else { return false }
        let bytes = Array(submitted.utf8)
        guard let dot = bytes.firstIndex(of: 0x2E) else { return false }
        let value = String(decoding: bytes[..<dot], as: UTF8.self)
        let mac = Array(bytes[(dot + 1)...])
        let expected = Array(hexEncode(hmacSHA256(key: Array(secret.utf8), message: Array(value.utf8))).utf8)
        let signatureOK = constantTimeEqual(expected, mac)
        let cookieOK = constantTimeEqual(Array(value.utf8), Array(cookieValue.utf8))
        return signatureOK && cookieOK
    }

    /// The Set-Cookie value for a freshly minted visitor value. `Secure` by default, to
    /// match the session cookie (both flags then behave consistently over TLS).
    static func setCookie(_ value: String, secure: Bool = true) -> String {
        var cookie = cookieName + "=" + value + "; Path=/; HttpOnly; SameSite=Lax"
        if secure { cookie += "; Secure" }
        return cookie
    }
}

extension Request {
    /// The submitted CSRF token from a urlencoded field, header, or multipart field.
    public var submittedCSRFToken: String? {
        if let token = form[CSRF.fieldName] { return token }
        if let token = headers.first(CSRF.headerName) { return token }
        if let multipart = multipart(), let token = multipart[CSRF.fieldName] { return token }
        return nil
    }

    /// The current request's CSRF token. Forms get this automatically through
    /// `@csrf`; you only need this to send the token another way (e.g. a header for
    /// a `fetch` POST). Returns "" when CSRF protection isn't configured.
    public func csrfToken() -> String { RenderContext.currentCSRFToken }

    var isUnsafeMethod: Bool {
        method == .post || method == .put || method == .patch || method == .delete
    }
}

/// Middleware that rejects unsafe requests without a valid CSRF token. The signing
/// secret is read from the SecretProvider by `secretName`.
public func csrfProtection(secretName: String = "CSRF_SECRET", secure: Bool = true) -> MiddlewareFunction {
    return { request, next in
        let secret = try await request.context.secrets?.secretString(secretName)
        let cookieValue = extractCookie(request, name: CSRF.cookieName)

        // Validate unsafe requests before running the handler. JSON and bearer-token
        // requests are exempt: a browser won't send them cross-site with ambient
        // cookies (they force a CORS preflight or aren't cookie-authenticated).
        let exempt = request.hasJSONBody || request.headers.first("authorization") != nil
        if request.isUnsafeMethod && !exempt {
            guard let secret, !secret.isEmpty else {
                return Response.text("500 CSRF secret not configured (set \(secretName))", status: 500)
            }
            guard CSRF.isValid(request.submittedCSRFToken, cookieValue: cookieValue, secret: secret) else {
                return Response.text("403 invalid or missing CSRF token", status: 403)
            }
        }

        // Establish this request's token for rendering: reuse the visitor's cookie
        // value, or mint one for a first-time visitor (and set the cookie on the way
        // out). Bind it as the ambient token so any `@csrf` in a view renders it —
        // no parameter threading, no per-handler wiring.
        var mintedCookie: String?
        let value: String
        if let cookieValue, !cookieValue.isEmpty {
            value = cookieValue
        } else {
            value = CSRF.mintValue()
            mintedCookie = CSRF.setCookie(value, secure: secure)
        }
        let token = (secret?.isEmpty == false) ? CSRF.token(value: value, secret: secret!) : ""

        // Bind the token as the ambient render value so any `@csrf` in a view renders
        // it. Task-local on the native server (concurrent requests); a plain global in
        // the single-threaded Wasm guest.
        #if hasFeature(Embedded)
        RenderContext.csrfToken = token
        var response = try await next(request)
        RenderContext.csrfToken = ""
        #else
        var response = try await RenderContext.$csrfToken.withValue(token) { try await next(request) }
        #endif
        if let mintedCookie, !token.isEmpty {
            response = response.settingCookie(mintedCookie)
        }
        return response
    }
}

// MARK: - HTTP method override

extension HTTPMethod {
    /// Map a `_method` override value (case-insensitive), unsafe methods only.
    public init?(override: String) {
        if asciiCaseInsensitiveEqual(override, "put") { self = .put }
        else if asciiCaseInsensitiveEqual(override, "patch") { self = .patch }
        else if asciiCaseInsensitiveEqual(override, "delete") { self = .delete }
        else { return nil }
    }
}

/// Middleware that rewrites a POST into PUT/PATCH/DELETE from a `_method` field
/// (or X-HTTP-Method-Override header) — HTML forms can only GET/POST. Runs before
/// routing, so the resourceful route matches the overridden method.
public func methodOverride() -> MiddlewareFunction {
    return { request, next in
        guard request.method == .post else { return try await next(request) }
        let value = request.form["_method"]
            ?? request.multipart()?["_method"]
            ?? request.headers.first("x-http-method-override")
        if let value, let overridden = HTTPMethod(override: value) {
            var rewritten = request
            rewritten.method = overridden
            return try await next(rewritten)
        }
        return try await next(request)
    }
}
