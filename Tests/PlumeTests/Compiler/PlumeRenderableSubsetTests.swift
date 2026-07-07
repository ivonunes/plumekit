//
//  PlumeRenderableSubsetTests.swift
//  PlumeTests — compiling back-end
//
//  The renderable-subset checker rejects build-time-only features with clear,
//  source-located messages, and accepts everything the back-end can lower.
//

import Testing

@testable import Plume

@Suite struct PlumeRenderableSubsetTests {
    func diagnostics(_ source: String) throws -> [PlumeError] {
        try PlumeTemplate(source, sourceName: "Subset.plume").renderableDiagnostics()
    }

    func messages(_ source: String) throws -> String {
        try diagnostics(source).map(\.message).joined(separator: "\n")
    }

    @Test func acceptsTheRenderableSubset() throws {
        let source = """
            @component Page(title: String, posts: [Post], user: User?) {
            <h1>{title}</h1>
            @if posts.size > 0 {
            <ul>@for post in posts {<li>{post.title | default("Untitled")}</li>}</ul>
            } else {
            <p>No posts</p>
            }
            @if user != nil {<span>member</span>}
            }
            @component Post(title: String) {}
            @component User(name: String) {}
            """
        #expect(try diagnostics(source).isEmpty)
    }

    @Test func acceptsScopedStylesStateAndScripts() throws {
        // These compile into the build-time bundle and emit HTML hooks,
        // so they are part of the renderable subset.
        #expect(try diagnostics("@component C() {@style(scoped) { .x { color: red; } }<i class=\"x\"></i>}").isEmpty)
        #expect(try diagnostics("@component C(n: Int) {@state count = n\n<p>x</p>}").isEmpty)
        #expect(try diagnostics("@component C() {@script(javascript) { var x = 1; }<p></p>}").isEmpty)
    }

    @Test func rejectsImageDirective() throws {
        #expect(try messages("@component C() {@image(\"a.png\", alt: \"\")}").contains("@image"))
    }

    @Test func rejectsBuildTimeFilter() throws {
        let messages = try messages("@component C(s: String) {{s | upcase}}")
        #expect(messages.contains("upcase"))
        #expect(messages.contains("build-time"))
    }

    @Test func rejectsBuildTimeMethod() throws {
        #expect(try messages("@component C(s: String) {{s.uppercased()}}").contains("uppercased"))
    }

    @Test func rejectsUntypedParameter() throws {
        let messages = try messages("@component C(name) {{name}}")
        #expect(messages.contains("name"))
        #expect(messages.contains("Swift type"))
    }

    @Test func reportsEveryViolationWithLocation() throws {
        let source = "@component C(name) {\n@image(\"a.png\", alt: \"\")\n{name | upcase}\n}"
        let diagnostics = try diagnostics(source)
        #expect(diagnostics.count == 3)  // untyped param, @image, upcase filter
        // Each diagnostic carries a source location pointing into the template.
        #expect(diagnostics.allSatisfy { $0.context != nil })
        #expect(diagnostics.contains { $0.context?.line == 2 })
    }
}
