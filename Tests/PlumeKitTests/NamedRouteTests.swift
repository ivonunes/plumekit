import Testing
import PlumeCore
import PlumeServer
import PlumeORM

@Suite struct NamedRouteTests {
    @Test func buildsPathsWithTypedArity() {
        let index = Route("/posts")
        let show = Route1("/posts/:id")
        let comment = Route2("/posts/:post_id/comments/:id")

        #expect(index.path == "/posts")
        #expect(show.path(42) == "/posts/42")
        #expect(show.path("hello-slug") == "/posts/hello-slug")
        #expect(comment.path(7, 3) == "/posts/7/comments/3")
    }

    @Test func substitutesMidPathParameters() {
        let nested = Route1("/teams/:team_id/members")
        #expect(nested.path(9) == "/teams/9/members")
    }

    @Test func registrationDispatchesThroughNamedRoutes() async {
        let app = Application()
        let show = Route1("/posts/:id")
        app.get(show) { req in .text("post \(req.parameters["id"] ?? "?")") }

        let response = await app.handle(Request(
            method: .get, path: show.path(5), query: "", headers: Headers(), body: [], context: .empty))
        #expect(String(decoding: response.body, as: UTF8.self) == "post 5")
    }
}

@Suite struct ModelBindingTests {
    @Model final class Widget: Model {
        var id: Int
        var label: String
    }

    private func request(parameters: [(String, String)]) -> Request {
        var request = Request(method: .get, path: "/widgets/1", query: "",
                              headers: Headers(), body: [], context: .empty)
        for (name, value) in parameters { request.parameters.set(name, value) }
        return request
    }

    @Test func findsTheModelFromTheRequestPathParameter() async throws {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Widget.createTable(in: db)
        let widget = Widget(label: "gear")
        _ = try await widget.save(in: db)

        let found = try await Widget.find(request(parameters: [("id", String(widget.id))]), in: db)
        #expect(found?.label == "gear")
    }

    @Test func missingRowOrBadIdYieldsNil() async throws {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Widget.createTable(in: db)

        #expect(try await Widget.find(request(parameters: [("id", "999")]), in: db) == nil)
        #expect(try await Widget.find(request(parameters: [("id", "not-a-number")]), in: db) == nil)
        #expect(try await Widget.find(request(parameters: []), in: db) == nil)
    }

    @Test func customParameterNameForNestedRoutes() async throws {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Widget.createTable(in: db)
        let widget = Widget(label: "cog")
        _ = try await widget.save(in: db)

        let found = try await Widget.find(request(parameters: [("widget_id", String(widget.id))]),
                                          parameter: "widget_id", in: db)
        #expect(found?.label == "cog")
    }
}
