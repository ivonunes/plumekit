import Testing
@testable import PlumeCore

private struct LoginForm: FormDecodable {
    let username: String
    let remember: Bool
    init(form: FormValues) {
        username = form.string("username")
        remember = form.bool("remember")
    }
}

@Test func typedFormDecode() {
    var headers = Headers()
    headers.set("content-type", "application/x-www-form-urlencoded")
    let request = Request(method: .post, path: "/login", headers: headers,
                          body: Array("username=ada&remember=on".utf8))
    let form = request.decode(LoginForm.self)
    #expect(form.username == "ada")
    #expect(form.remember == true)            // "on" → true
}

@Test func sha256KnownVectors() {
    #expect(hexEncode(SHA256.hash(Array("abc".utf8)))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(hexEncode(SHA256.hash([]))
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@Test func hmacSHA256KnownVector() {
    // RFC 4231 test case 1: key = 20×0x0b, data = "Hi There"
    let key = [UInt8](repeating: 0x0b, count: 20)
    let mac = hmacSHA256(key: key, message: Array("Hi There".utf8))
    #expect(hexEncode(mac) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
}

@Test func csrfTokenMintsAndValidates() {
    let secret = "super-secret-signing-key"
    let value = CSRF.mintValue()
    let token = CSRF.token(value: value, secret: secret)

    #expect(CSRF.mintValue() != CSRF.mintValue())                                   // per-visitor, unpredictable
    #expect(CSRF.isValid(token, cookieValue: value, secret: secret))                // matched pair passes
    #expect(!CSRF.isValid(token, cookieValue: CSRF.mintValue(), secret: secret))    // stolen token, other visitor → no
    #expect(!CSRF.isValid(token, cookieValue: nil, secret: secret))                 // no cookie → no
    #expect(!CSRF.isValid("forged.deadbeef", cookieValue: "forged", secret: secret))// planted pair, unsigned → no
    #expect(!CSRF.isValid(nil, cookieValue: value, secret: secret))                 // missing token → no
    #expect(!CSRF.isValid(token, cookieValue: value, secret: "different-key"))      // wrong key → no
}

@Test func constantTimeEqualWorks() {
    #expect(constantTimeEqual([1, 2, 3], [1, 2, 3]))
    #expect(!constantTimeEqual([1, 2, 3], [1, 2, 4]))
    #expect(!constantTimeEqual([1, 2], [1, 2, 3]))
}

@Test func methodOverrideParsing() {
    #expect(HTTPMethod(override: "put") == .put)
    #expect(HTTPMethod(override: "PATCH") == .patch)
    #expect(HTTPMethod(override: "Delete") == .delete)
    #expect(HTTPMethod(override: "post") == nil)   // only PUT/PATCH/DELETE
}

@Test func methodOverrideMiddlewareRewritesPost() async throws {
    let app = Application()
    app.use(methodOverride())
    app.put("/posts/:id") { _ in .text("updated") }
    // HTML form: POST with _method=put
    let body = Array("_method=put".utf8)
    var headers = Headers()
    headers.set("content-type", "application/x-www-form-urlencoded")
    let response = await app.handle(Request(method: .post, path: "/posts/9", headers: headers, body: body))
    #expect(response.status == 200)
    #expect(decodeUTF8(response.body) == "updated")
}

@Test func csrfMiddlewareRejectsAndAccepts() async throws {
    let secret = "k"
    let secrets = Secrets(secret: { name in name == "CSRF_SECRET" ? Array(secret.utf8) : nil })
    let context = Context(secrets: secrets)
    let app = Application()
    app.use(csrfProtection())
    app.post("/posts") { _ in .text("created", status: 201) }

    // missing token → 403
    var headers = Headers()
    headers.set("content-type", "application/x-www-form-urlencoded")
    let denied = await app.handle(Request(method: .post, path: "/posts", headers: headers, context: context))
    #expect(denied.status == 403)

    // matched cookie + signed token → passes
    let value = CSRF.mintValue()
    var ok = Headers()
    ok.set("content-type", "application/x-www-form-urlencoded")
    ok.set("cookie", CSRF.cookieName + "=" + value)
    ok.set(CSRF.headerName, CSRF.token(value: value, secret: secret))
    let allowed = await app.handle(Request(method: .post, path: "/posts", headers: ok, context: context))
    #expect(allowed.status == 201)

    // signed token from a DIFFERENT visitor's cookie → rejected
    var stolen = Headers()
    stolen.set("content-type", "application/x-www-form-urlencoded")
    stolen.set("cookie", CSRF.cookieName + "=" + CSRF.mintValue())
    stolen.set(CSRF.headerName, CSRF.token(value: value, secret: secret))
    let rejected = await app.handle(Request(method: .post, path: "/posts", headers: stolen, context: context))
    #expect(rejected.status == 403)
}

@Test func csrfMintsTheCookieOnFirstRender() async throws {
    let secret = "k"
    let secrets = Secrets(secret: { name in name == "CSRF_SECRET" ? Array(secret.utf8) : nil })
    let context = Context(secrets: secrets)
    let app = Application()
    app.use(csrfProtection())
    app.get("/form") { request in .html("token=\(request.csrfToken())") }

    // First visit: token minted, cookie set on the response, token bound to it.
    let first = await app.handle(Request(method: .get, path: "/form", context: context))
    let setCookie = first.headers.all("set-cookie").first { $0.hasPrefix(CSRF.cookieName + "=") }
    #expect(setCookie != nil)
    let value = String(setCookie!.dropFirst((CSRF.cookieName + "=").count).prefix { $0 != ";" })
    #expect(decodeUTF8(first.body).contains("token=" + CSRF.token(value: value, secret: secret)))

    // Returning visitor: same cookie → same token, no re-set.
    var headers = Headers()
    headers.set("cookie", CSRF.cookieName + "=" + value)
    let second = await app.handle(Request(method: .get, path: "/form", headers: headers, context: context))
    #expect(second.headers.all("set-cookie").isEmpty)
    #expect(decodeUTF8(second.body).contains("token=" + CSRF.token(value: value, secret: secret)))
}
