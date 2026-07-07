//
//  PlumeSourceLocationTests.swift
//  PlumeTests — compiling back-end
//
//  Proves the two-layer checking model's payoff: a *type* error in a template
//  (which Plume defers to `swiftc`) is reported against the `.plume` source line,
//  not against generated Swift, thanks to emitted `#sourceLocation` directives.
//

import Testing

@testable import Plume

@Suite struct PlumeSourceLocationTests {
    @Test func typeErrorPointsAtTemplateLine() throws {
        // `count` is an Int; `.title` does not exist. The bad interpolation is on
        // line 2 of the template.
        let template = "@component Bad(count: Int) {\n<p>{count.title}</p>\n}\n"
        let result = try RenderHarness.compileDiagnostics(
            template: template,
            sourceName: "Bad.plume",
            fixtures: "",
            call: "bad(count: 1, into: &out)")

        #expect(!result.succeeded, "the template should fail to compile")
        #expect(
            result.output.contains("Bad.plume:2"),
            "diagnostic should point at the .plume line, got:\n\(result.output)")
    }
}
