import Testing
@testable import PlumeCore

// Route groups (prefix + scoped middleware) and catch-all wildcards.

private func req(_ method: HTTPMethod, _ path: String) -> Request {
    Request(method: method, path: path)
}

private func header(_ key: String, _ value: String) -> MiddlewareFunction {
    { request, next in
        var response = try await next(request)
        response.headers.add(key, value)
        return response
    }
}

@Test func groupPrefixesRoutePaths() async {
    let app = Application()
    app.group("/admin") { admin in
        admin.get("/users") { _ in .text("users") }
    }
    #expect(await app.handle(req(.get, "/admin/users")).bodyText == "users")
    #expect(await app.handle(req(.get, "/users")).status == 404)
}

@Test func groupMiddlewareIsScopedToTheGroup() async {
    let app = Application()
    app.group("/admin", middleware: [header("x-scope", "admin")]) { admin in
        admin.get("/x") { _ in .text("x") }
    }
    app.get("/open") { _ in .text("open") }

    #expect(await app.handle(req(.get, "/admin/x")).headers.first("x-scope") == "admin")
    #expect(await app.handle(req(.get, "/open")).headers.first("x-scope") == nil)
}

@Test func nestedGroupsComposePrefixAndMiddleware() async {
    let app = Application()
    app.group("/api", middleware: [header("x-a", "1")]) { api in
        api.group("/v1", middleware: [header("x-b", "2")]) { v1 in
            v1.get("/ping") { _ in .text("pong") }
        }
    }
    let response = await app.handle(req(.get, "/api/v1/ping"))
    #expect(response.bodyText == "pong")
    #expect(response.headers.first("x-a") == "1")
    #expect(response.headers.first("x-b") == "2")
}

@Test func wildcardCapturesTheRestOfThePath() async {
    let app = Application()
    app.get("/files/*path") { request in .text(request.parameters["path"] ?? "?") }
    #expect(await app.handle(req(.get, "/files/a/b/c.txt")).bodyText == "a/b/c.txt")
    #expect(await app.handle(req(.get, "/files/single")).bodyText == "single")
}

@Test func wildcardRequiresAtLeastOneSegment() async {
    let app = Application()
    app.get("/files/*path") { _ in .text("ok") }
    #expect(await app.handle(req(.get, "/files")).status == 404)
}

@Test func doubleWildcardMatchesZeroOrMoreSegments() async {
    let app = Application()
    app.get("/assets/**path") { request in .text("[\(request.parameters["path"] ?? "")]") }
    #expect(await app.handle(req(.get, "/assets/a/b")).bodyText == "[a/b]")
    #expect(await app.handle(req(.get, "/assets")).bodyText == "[]")   // matches the bare prefix
}
