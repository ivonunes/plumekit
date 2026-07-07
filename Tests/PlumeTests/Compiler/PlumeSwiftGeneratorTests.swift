//
//  PlumeSwiftGeneratorTests.swift
//  PlumeTests — compiling back-end
//
//  Fast, compilation-free tests over the *shape* of the generated Swift source.
//  Rendered-byte behaviour is proven separately by PlumeCompiledRenderTests.
//

import Testing

@testable import Plume

@Suite struct PlumeSwiftGeneratorTests {
    func generate(_ source: String, sourceLocations: Bool = false) throws -> String {
        try PlumeSwiftBackend.generate(
            source: source,
            sourceName: "Test.plume",
            options: PlumeSwiftOptions(emitSourceLocations: sourceLocations))
    }

    @Test func lowersTypedComponentToFunction() throws {
        let swift = try generate("@component Greeting(name: String) {\n  <p>Hello, {name}!</p>\n}")
        #expect(swift.contains("import PlumeRuntime"))
        #expect(swift.contains("func greeting(name: String, into out: inout HTML) {"))
    }

    @Test func interpolationEscapesByDefault() throws {
        let swift = try generate("@component Greeting(name: String) {\n{name}\n}")
        #expect(swift.contains("out.text(name)"))
        #expect(!swift.contains("out.raw(name)"))
    }

    @Test func rawFilterOptsOutOfEscaping() throws {
        let swift = try generate("@component Page(body: String) {\n{body | raw}\n}")
        #expect(swift.contains("out.raw(body)"))
    }

    // A `{` glued to a word char inside a QUOTED ATTRIBUTE VALUE is an
    // interpolation (`class="app-header{extra}"`), even though the same `word{`
    // in raw <style>/<script>/prose stays literal (CSS/JS block braces).
    @Test func interpolationGluedToWordCharInsideQuotedAttribute() throws {
        let swift = try generate(#"@component C(extra: String) {<a class="app-header{extra}">x</a>}"#)
        #expect(swift.contains("out.text(extra)"))
        #expect(!swift.contains("app-header{extra}"))
    }

    @Test func wordBraceStaysLiteralInRawStyleAndScript() throws {
        let css = try generate("@component S() {<style>.a{ color: red }</style>}")
        #expect(css.contains(".a{ color: red }"))
        #expect(!css.contains("out.text("))

        let js = try generate("@component J() {<script>function f(){ go() }</script>}")
        #expect(js.contains("function f(){ go() }"))
        #expect(!js.contains("out.text("))
    }

    @Test func textBecomesLiteralBytes() throws {
        let swift = try generate("@component Hr() {\n<hr>\n}")
        #expect(swift.contains("out.literal("))
        #expect(swift.contains("<hr>"))
    }

    @Test func memberPathLowersToSwiftAccess() throws {
        let swift = try generate("@component Card(post: Post) {\n{post.title}\n}")
        #expect(swift.contains("out.text(post.title)"))
    }

    @Test func defaultsBecomeSwiftDefaultArguments() throws {
        let swift = try generate(
            "@component List(items: [Post] = [], heading: String = \"Posts\") {\n{heading}\n}")
        #expect(swift.contains("items: [Post] = []"))
        #expect(swift.contains("heading: String = \"Posts\""))
    }

    @Test func optionalPropStaysOptional() throws {
        let swift = try generate("@component Card(user: User?) {\n{user.name}\n}")
        #expect(swift.contains("user: User?"))
    }

    @Test func sourceLocationsPointAtTemplateLine() throws {
        let swift = try generate(
            "@component Greeting(name: String) {\n<p>{name}</p>\n}", sourceLocations: true)
        #expect(swift.contains("#sourceLocation(file: \"Test.plume\", line: 2)"))
        #expect(swift.contains("#sourceLocation()"))
    }

    @Test func untypedParameterIsRejected() throws {
        #expect(throws: PlumeError.self) {
            try generate("@component Greeting(name) {\n{name}\n}")
        }
    }

    // MARK: - Control flow (step 2)

    @Test func conditionalLowersToSwiftIfElse() throws {
        let swift = try generate(
            "@component C(flag: Bool) {@if flag {<a>}else{<b>}}")
        #expect(swift.contains("if Plume.truthy(flag) {"))
        #expect(swift.contains("} else {"))
    }

    @Test func elseIfChainCollapses() throws {
        let swift = try generate(
            "@component G(score: Int) {@if score >= 90 {A} else if score >= 80 {B} else {C}}")
        #expect(swift.contains("if Plume.truthy((score >= 90)) {"))
        #expect(swift.contains("} else if Plume.truthy((score >= 80)) {"))
        #expect(swift.contains("} else {"))
    }

    @Test func loopLowersToSwiftFor() throws {
        let swift = try generate(
            "@component L(posts: [Post]) {@for post in posts {<li>{post.title}</li>}}")
        #expect(swift.contains("for post in posts {"))
        #expect(swift.contains("out.text(post.title)"))
    }

    @Test func loopReferencingForLoopUsesEnumerated() throws {
        let swift = try generate(
            "@component L(posts: [Post]) {@for post in posts {{forloop.index}}}")
        #expect(swift.contains(".enumerated()"))
        #expect(swift.contains("PlumeForLoop(index:"))
        #expect(swift.contains("out.text(forloop.index)"))
    }

    @Test func comparisonAndLogicLowerWithParentheses() throws {
        let swift = try generate(
            "@component C(a: Int, b: Int) {@if a > 0 && b < 10 {<x>}}")
        #expect(swift.contains("((a > 0) && (b < 10))"))
    }

    @Test func letAssignmentLowersToSwiftLet() throws {
        let swift = try generate(
            "@component C(posts: [Post]) {@let total = posts.size\n<p>{total}</p>}")
        #expect(swift.contains("let total = posts.count"))
    }

    // MARK: - Components & slots (step 3)

    @Test func componentCallLowersToTypedFunctionCall() throws {
        let swift = try generate(
            "@component Box(a: Int, b: Int) {<i>{a}</i>}\n@component Use() {@Box(b: 2, a: 1)}")
        // Arguments are reordered to match the declared parameter order.
        #expect(swift.contains("box(a: 1, b: 2, into: &out)"))
    }

    @Test func slotsBecomeOptionalClosureParameters() throws {
        let swift = try generate(
            "@component Card(title: String) {<div>@slot(body){fallback}</div>}")
        #expect(swift.contains("body: ((inout HTML) -> Void)? = nil"))
        // The slot renders into a buffer so it can fall back when it renders EMPTY (not
        // just when absent), matching the interpreter.
        #expect(swift.contains("if let body { body(&__plume_slot"))
        #expect(swift.contains(".bytes.isEmpty {"))
    }

    @Test func defaultSlotUsesSlotParameter() throws {
        let swift = try generate("@component Card() {<div>@slot{none}</div>}")
        #expect(swift.contains("slot: ((inout HTML) -> Void)? = nil"))
        #expect(swift.contains("if let slot {"))
    }

    @Test func callPassesSlotClosures() throws {
        let swift = try generate(
            "@component Card(title: String) {@slot{x}@slot(footer){y}}\n"
            + "@component Page() {@Card(title: \"t\"){body@content(footer){f}}}")
        #expect(swift.contains("slot: { out in"))
        #expect(swift.contains("footer: { out in"))
    }

    // MARK: - Filters & methods (step 4)

    @Test func numericFiltersLowerToSwiftArithmetic() throws {
        let swift = try generate("@component N(x: Int) {{x | plus(2) | times(3)}}")
        #expect(swift.contains("out.text(((x + 2) * 3))"))
    }

    @Test func defaultFilterUsesRuntimeHelper() throws {
        let swift = try generate("@component N(x: String?) {{x | default(\"-\")}}")
        #expect(swift.contains("Plume.defaulted(x, \"-\")"))
    }

    @Test func stringEqualityRoutesThroughByteWiseHelper() throws {
        let swift = try generate("@component N(s: String) {@if s == \"a\" {y}}")
        #expect(swift.contains("Plume.equal(s, \"a\")"))
        #expect(!swift.contains("(s == \"a\")"))
    }

    @Test func nilComparisonStaysNative() throws {
        let swift = try generate("@component N(s: String?) {@if s != nil {y}}")
        #expect(swift.contains("(s != nil)"))
    }

    @Test func predicateMethodLowersToRuntimeHelper() throws {
        let swift = try generate("@component N(s: String) {@if s.hasPrefix(\"/\") {y}}")
        #expect(swift.contains("Plume.hasPrefix(s, \"/\")"))
    }

    @Test func buildTimeFilterIsRejected() throws {
        #expect(throws: PlumeError.self) {
            try generate("@component N(s: String) {{s | upcase}}")
        }
    }

    @Test func buildTimeMethodIsRejected() throws {
        #expect(throws: PlumeError.self) {
            try generate("@component N(s: String) {{s.uppercased()}}")
        }
    }

    // MARK: - Behaviour hooks

    @Test func scopedStyleAddsScopeAttributesAndDropsCSS() throws {
        let swift = try generate(
            "@component C() {@style(scoped) {.x{color:red}}<div class=\"x\"><span></span></div>}")
        #expect(swift.contains("<div data-plume-scope-plume-"))
        #expect(swift.contains("<span data-plume-scope-plume-"))
        #expect(!swift.contains("color:red"))  // CSS goes to the bundle, not the render fn
    }

    @Test func stateLowersToSerializedHook() throws {
        let swift = try generate("@component C(n: Int) {@state count = n\n<p>x</p>}")
        #expect(swift.contains("data-plume-state"))
        #expect(swift.contains(#"\"count\":"#))
        #expect(swift.contains("out.jsonValue(n)"))
    }

    @Test func navigationLowersToStaticMarker() throws {
        let swift = try generate(
            "@component C() {@navigation(root: \"main\", scroll: \"preserve\")\n<p></p>}")
        #expect(swift.contains("data-plume-navigation"))
        #expect(swift.contains("\\\"root\\\":\\\"main\\\""))
        #expect(swift.contains("\\\"scroll\\\":\\\"preserve\\\""))
        #expect(swift.contains("\\\"progressBar\\\":true"))
        #expect(swift.contains("\\\"progressBarDelay\\\":500"))
    }

    @Test func unscopedStyleEmitsNoScopeAttributes() throws {
        let swift = try generate("@component C() {@style {.x{color:red}}<div></div>}")
        #expect(!swift.contains("data-plume-scope"))
    }

    // MARK: - Syntax Swiftification

    @Test func nilCoalescingLowersToSwiftOperator() throws {
        let swift = try generate(#"@component C(name: String?) {{name ?? "x"}}"#)
        #expect(swift.contains(#"out.text((name ?? "x"))"#))
    }

    @Test func ifLetLowersToSwiftOptionalBinding() throws {
        let swift = try generate(
            "@component C(user: User?) {@if let u = user {<p>{u.name}</p>}}")
        #expect(swift.contains("if let u = user {"))
        #expect(swift.contains("out.text(u.name)"))
    }

    @Test func elseIfLetLowersToSwift() throws {
        let swift = try generate(
            "@component C(a: User?, b: User?) {@if let x = a {1} else if let y = b {2} else {3}}")
        #expect(swift.contains("if let x = a {"))
        #expect(swift.contains("} else if let y = b {"))
    }

    @Test func bangBindsTighterThanComparison() throws {
        // Swift precedence: `!active == false` is `(!active) == false`.
        let swift = try generate("@component N(active: Bool) {@if !active == false {<b></b>}}")
        #expect(swift.contains("Plume.equal((!active), false)"))
    }
}
