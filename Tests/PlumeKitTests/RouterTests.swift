import Testing
@testable import PlumeCore

// In-process tests of the portable core. No sockets, no Wasm — these exercise
// the router and middleware exactly as both adapters do, by calling
// `Application.handle(_:)` directly. Handlers are now `async throws`.

private func request(_ method: HTTPMethod, _ path: String) -> Request {
    Request(method: method, path: path)
}

@Test func rootRouteMatches() async {
    let app = Application()
    app.get("/") { _ in .text("Hello from PlumeKit") }

    let response = await app.handle(request(.get, "/"))
    #expect(response.status == 200)
    #expect(response.bodyText == "Hello from PlumeKit")
}

@Test func pathParameterIsCaptured() async {
    let app = Application()
    app.get("/hello/:name") { req in
        .text("Hello, \(req.parameters["name"] ?? "?")!")
    }

    let response = await app.handle(request(.get, "/hello/ada"))
    #expect(response.status == 200)
    #expect(response.bodyText == "Hello, ada!")
}

@Test func multipleParametersAreCaptured() async {
    let app = Application()
    app.get("/users/:user/posts/:post") { req in
        .text("\(req.parameters["user"] ?? "")/\(req.parameters["post"] ?? "")")
    }

    let response = await app.handle(request(.get, "/users/ada/posts/42"))
    #expect(response.bodyText == "ada/42")
}

@Test func unknownPathReturns404() async {
    let app = Application()
    app.get("/") { _ in .text("root") }

    #expect(await app.handle(request(.get, "/nope")).status == 404)
}

@Test func wrongMethodReturns405() async {
    let app = Application()
    app.get("/only-get") { _ in .text("ok") }

    let response = await app.handle(request(.post, "/only-get"))
    #expect(response.status == 405)
}

@Test func methodsAreRoutedIndependently() async {
    let app = Application()
    app.get("/r") { _ in .text("get") }
    app.post("/r") { _ in .text("post") }

    #expect(await app.handle(request(.get, "/r")).bodyText == "get")
    #expect(await app.handle(request(.post, "/r")).bodyText == "post")
}

@Test func thrownErrorBecomes500() async {
    struct Boom: Error {}
    let app = Application()
    app.get("/boom") { _ in throw Boom() }

    #expect(await app.handle(request(.get, "/boom")).status == 500)
}

@Test func trailingAndLeadingSlashesNormalize() async {
    let app = Application()
    app.get("/a/b") { _ in .text("ab") }

    #expect(await app.handle(request(.get, "/a/b")).status == 200)
    #expect(await app.handle(request(.get, "//a//b//")).status == 200)
}

@Test func middlewareRunsInRegistrationOrderAroundHandler() async {
    let app = Application()
    let trail = Trail()

    app.use { req, next in
        await trail.add("A-before")
        let res = try await next(req)
        await trail.add("A-after")
        return res
    }
    app.use { req, next in
        await trail.add("B-before")
        let res = try await next(req)
        await trail.add("B-after")
        return res
    }
    app.get("/") { _ in
        await trail.add("handler")
        return .text("ok")
    }

    _ = await app.handle(request(.get, "/"))
    #expect(await trail.entries == ["A-before", "B-before", "handler", "B-after", "A-after"])
}

private actor Trail {
    var entries: [String] = []
    func add(_ s: String) { entries.append(s) }
}

@Test func middlewareCanShortCircuit() async {
    let app = Application()
    app.use { req, next in
        if req.headers.first("x-api-key") == nil {
            return .text("unauthorized", status: 401)
        }
        return try await next(req)
    }
    app.get("/secret") { _ in .text("secret") }

    #expect(await app.handle(request(.get, "/secret")).status == 401)

    var authed = request(.get, "/secret")
    authed.headers.add("x-api-key", "let-me-in")
    #expect(await app.handle(authed).status == 200)
}

struct PassthroughMiddleware: Middleware {
    func respond(to request: Request, next: Responder) async throws -> Response {
        try await next(request)
    }
}

@Test func protocolMiddlewareIsAccepted() async {
    let app = Application()
    app.use(PassthroughMiddleware())
    app.get("/x") { _ in .text("x") }
    #expect(await app.handle(request(.get, "/x")).bodyText == "x")
}

@Test func headersAreCaseInsensitive() {
    var headers = Headers()
    headers.add("Content-Type", "text/plain")
    #expect(headers.first("content-type") == "text/plain")
    #expect(headers.first("CONTENT-TYPE") == "text/plain")
    #expect(headers.first("missing") == nil)
}

@Test func responseConveniencesSetContentType() {
    #expect(Response.text("hi").headers.first("content-type") == "text/plain; charset=utf-8")
    #expect(Response.html("<p>").headers.first("content-type") == "text/html; charset=utf-8")
    #expect(Response.json("{}").headers.first("content-type") == "application/json; charset=utf-8")
}

@Test func staticRouteBeatsParamRegardlessOfOrder() async {
    let app = Application()
    app.get("/users/:id") { req in .text("param:\(req.parameters["id"] ?? "")") }
    app.get("/users/new") { _ in .text("static") }   // registered AFTER the param route
    #expect(await app.handle(request(.get, "/users/new")).bodyText == "static")
    #expect(await app.handle(request(.get, "/users/42")).bodyText == "param:42")
}

@Test func pathParamsArePercentDecoded() async {
    let app = Application()
    app.get("/files/:name") { req in .text(req.parameters["name"] ?? "") }
    #expect(await app.handle(request(.get, "/files/my%20file.txt")).bodyText == "my file.txt")
    #expect(await app.handle(request(.get, "/files/a%2Fb")).bodyText == "a/b")
}

@Test func headFallsBackToGetWithNoBody() async {
    let app = Application()
    app.get("/page") { _ in .html("<h1>hi</h1>") }
    let response = await app.handle(request(.head, "/page"))
    #expect(response.status == 200)
    #expect(response.body.isEmpty)                       // HEAD: headers only
    #expect(response.headers.first("content-type") != nil)
}

private enum RouterTestError: Error { case boom }

@Test func percentEncodedSegmentMatchesLiteralNotParam() async {
    let app = Application()
    app.get("/admin/settings") { _ in .text("literal") }
    app.get("/admin/:page") { _ in .text("param") }
    // %65 == 'e'; the encoded spelling of the literal path must hit the literal route,
    // not silently fall through to the :param handler (an auth/behavior mismatch).
    let r = await app.handle(request(.get, "/admin/s%65ttings"))
    #expect(r.bodyText == "literal")
}

@Test func customErrorPagesRenderForNotFoundThrowAndBodylessStatus() async {
    let app = Application()
    app.errorPage(404) { _ in .html("<h1>Missing</h1>", status: 404) }
    app.errorPage(500) { _ in .html("<h1>Oops</h1>", status: 500) }
    app.errorPage(403) { _ in .html("<h1>Denied</h1>", status: 403) }
    app.get("/boom") { _ in throw RouterTestError.boom }
    app.get("/deny") { _ in .status(403) }          // bodyless error status

    let nf = await app.handle(request(.get, "/nope"))
    #expect(nf.status == 404 && nf.bodyText == "<h1>Missing</h1>")
    let err = await app.handle(request(.get, "/boom"))
    #expect(err.status == 500 && err.bodyText == "<h1>Oops</h1>")
    let denied = await app.handle(request(.get, "/deny"))
    #expect(denied.status == 403 && denied.bodyText == "<h1>Denied</h1>")
}

@Test func defaultErrorPagesUnchangedWhenNoCustomRegistered() async {
    let app = Application()
    app.get("/x") { _ in .text("ok") }
    let nf = await app.handle(request(.get, "/nope"))
    #expect(nf.status == 404 && nf.bodyText == "404 Not Found")   // default preserved
}

@Test func routeRegisteredWithAPercentEscapeLiteralStaysReachable() async {
    let app = Application()
    app.get("/a%20b") { _ in .text("hit") }
    let r = await app.handle(request(.get, "/a%20b"))
    #expect(r.bodyText == "hit")   // decode-both-sides: was unreachable after the literal-decode change
}

final class _InvokeCounter: @unchecked Sendable { var count = 0 }

@Test func bodylessCustomErrorPageIsInvokedExactlyOnce() async {
    let app = Application()
    let counter = _InvokeCounter()
    app.errorPage(404) { _ in counter.count += 1; return .status(404) }   // bodyless page
    let r = await app.handle(request(.get, "/nope"))
    #expect(r.status == 404)
    #expect(counter.count == 1)    // was 2 (dispatch + post-invoke rewrite) before the fix
}

private struct PhotosController: Controller {
    func index(_ r: Request) async throws -> Response { .text("index") }
    func new(_ r: Request) async throws -> Response { .text("new-form") }
    func show(_ r: Request) async throws -> Response { .text("show \(r.parameters["id"] ?? "?")") }
    func edit(_ r: Request) async throws -> Response { .text("edit-form \(r.parameters["id"] ?? "?")") }
}

@Test func resourcesWiresNewAndEditFormActions() async {
    let app = Application()
    app.resources("/photos", PhotosController())
    #expect(await app.handle(request(.get, "/photos")).bodyText == "index")
    #expect(await app.handle(request(.get, "/photos/new")).bodyText == "new-form")      // NOT captured by /:id
    #expect(await app.handle(request(.get, "/photos/42")).bodyText == "show 42")
    #expect(await app.handle(request(.get, "/photos/42/edit")).bodyText == "edit-form 42")
    // Unimplemented actions still fall back to 405.
    #expect(await app.handle(request(.post, "/photos")).status == 405)
    #expect(await app.handle(request(.delete, "/photos/42")).status == 405)
}
