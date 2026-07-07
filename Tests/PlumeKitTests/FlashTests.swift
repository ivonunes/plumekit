import Testing
@testable import PlumeCore

@Suite struct FlashTests {
    private func request(path: String = "/", cookie: String? = nil) -> Request {
        var headers = Headers()
        if let cookie { headers.add("cookie", cookie) }
        return Request(method: .get, path: path, query: "", headers: headers, body: [], context: .empty)
    }

    @Test func fluentFlashSetsTheCookie() {
        let response = Response.redirect(to: "/posts").flash("Post created", kind: Flash.success)
        let cookie = response.headers.all("set-cookie").first { $0.hasPrefix("plumekit_flash=") }
        #expect(cookie != nil)
        #expect(cookie?.contains("Max-Age=60") == true)
        #expect(cookie?.contains("SameSite=Lax") == true)
    }

    @Test func roundTripsKindAndMessageWithSpecialCharacters() {
        let message = "Saved “Post #1” — 100% & <done>."
        let cookie = Flash.setCookie(kind: Flash.error, message: message)
        // Extract the payload between "plumekit_flash=" and the first ";".
        let payload = String(cookie.dropFirst("plumekit_flash=".count).prefix { $0 != ";" })
        let parsed = Flash.parse(payload)
        #expect(parsed?.kind == Flash.error)
        #expect(parsed?.message == message)
    }

    @Test func requestReadsTheFlashCookie() {
        let cookie = Flash.setCookie(kind: Flash.notice, message: "hello there")
        let payload = String(cookie.dropFirst("plumekit_flash=".count).prefix { $0 != ";" })
        let req = request(cookie: "other=1; plumekit_flash=\(payload)")
        #expect(req.flash?.message == "hello there")
        #expect(req.flash?.kind == Flash.notice)
        #expect(request().flash == nil)
    }

    @Test func showsExactlyOnceAcrossTheRedirectFlow() async {
        let app = Application()
        app.post("/posts") { _ in .redirect(to: "/posts").flash("Post created") }
        app.get("/posts") { req in .html(req.flash?.message ?? "(none)") }
        app.get("/poll") { _ in .json("{\"n\":1}") }

        // 1. The create sets the flash on the redirect.
        let redirect = await app.handle(request(path: "/posts").with(method: .post))
        let setCookie = redirect.headers.all("set-cookie").first { $0.hasPrefix("plumekit_flash=") }
        #expect(setCookie != nil)
        let payload = String(setCookie!.dropFirst("plumekit_flash=".count).prefix { $0 != ";" })

        // 2. A JSON poll carrying the cookie must NOT consume the flash.
        let poll = await app.handle(request(path: "/poll", cookie: "plumekit_flash=\(payload)"))
        #expect(poll.headers.all("set-cookie").isEmpty)

        // 3. The next HTML page view renders it, and the framework clears the cookie.
        let page = await app.handle(request(path: "/posts", cookie: "plumekit_flash=\(payload)"))
        #expect(String(decoding: page.body, as: UTF8.self) == "Post created")
        let clear = page.headers.all("set-cookie").first { $0.hasPrefix("plumekit_flash=") }
        #expect(clear?.contains("Max-Age=0") == true)

        // 4. A view without the cookie sees nothing, and nothing is cleared.
        let after = await app.handle(request(path: "/posts"))
        #expect(String(decoding: after.body, as: UTF8.self) == "(none)")
        #expect(after.headers.all("set-cookie").isEmpty)
    }

    @Test func settingANewFlashWinsOverClearing() async {
        let app = Application()
        // A handler that both consumes a flash and sets a new one (redirect chain).
        app.get("/step") { _ in .redirect(to: "/next").flash("Step two") }

        let payload = "notice.old"
        let response = await app.handle(request(path: "/step", cookie: "plumekit_flash=\(payload)"))
        let cookies = response.headers.all("set-cookie").filter { $0.hasPrefix("plumekit_flash=") }
        #expect(cookies.count == 1)                       // the new flash, no clearing entry
        #expect(cookies[0].contains("Max-Age=60"))
    }
}

private extension Request {
    func with(method: HTTPMethod) -> Request {
        Request(method: method, path: path, query: query, headers: headers, body: body, context: context)
    }
}
