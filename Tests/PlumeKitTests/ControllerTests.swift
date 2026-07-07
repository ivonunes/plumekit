import Testing
@testable import PlumeCore

private struct DemoController: Controller {
    func index(_ request: Request) async throws -> Response { .text("index") }
    func show(_ request: Request) async throws -> Response { .text("show \(request.parameters["id"] ?? "?")") }
    func create(_ request: Request) async throws -> Response { .text("create", status: 201) }
    // update / destroy use the default 405
}

@Test func resourcesRoutesToActions() async throws {
    let app = Application()
    app.resources("/posts", DemoController())

    let index = await app.handle(Request(method: .get, path: "/posts"))
    #expect(index.status == 200)
    #expect(decodeUTF8(index.body) == "index")

    let show = await app.handle(Request(method: .get, path: "/posts/42"))
    #expect(decodeUTF8(show.body) == "show 42")

    let create = await app.handle(Request(method: .post, path: "/posts"))
    #expect(create.status == 201)

    // unimplemented actions fall back to 405
    let destroy = await app.handle(Request(method: .delete, path: "/posts/1"))
    #expect(destroy.status == 405)
    let update = await app.handle(Request(method: .put, path: "/posts/1"))
    #expect(update.status == 405)
}

@Test func formParamsParseAndDecode() {
    let form = FormParams("title=Hello+World&views=3&empty=")
    #expect(form["title"] == "Hello World")     // '+' → space
    #expect(form.int("views") == 3)
    #expect(form["empty"] == "")
    #expect(form["missing"] == nil)

    let encoded = FormParams("name=a%26b%20c")  // %26 = '&', %20 = space
    #expect(encoded["name"] == "a&b c")
}
