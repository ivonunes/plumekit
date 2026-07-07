//
//  PlumeCompiledRenderTests.swift
//  PlumeTests — compiling back-end
//
//  Proves that generated Swift actually compiles, links, and renders the expected
//  bytes. The native suite always runs. The Embedded-Wasm gate runs whenever the
//  Embedded SDK and Node are present (always, in CI); it is the link-and-run check
//  that a library-only build cannot provide.
//

import Testing

@testable import Plume

@Suite struct PlumeCompiledRenderTests {
    /// The fixture model types every render case may reference.
    static let fixtures = """
        struct Post { var title: String; var slug: String }
        struct User { var name: String }
        struct Article { var title: String; var author: User; var tags: [String] }
        """

    /// One template + call per case, shared by the native and embedded suites so
    /// both back-ends are proven to agree byte-for-byte.
    static let cases: [RenderCase] = [
        // Step 1: interpolation, escaping, raw opt-out, member access.
        RenderCase(
            name: "greeting",
            template: "@component Greeting(name: String) {<p>Hello, {name}!</p>}",
            call: #"greeting(name: "Ann & <Bob>", into: &out)"#),
        RenderCase(
            name: "raw",
            template: "@component Page(body: String) {<main>{body | raw}</main>}",
            call: #"page(body: "<b>safe</b>", into: &out)"#),
        RenderCase(
            name: "member",
            template: "@component Card(post: Post) {<h1>{post.title}</h1>}",
            call: #"card(post: Post(title: "A <Tag>", slug: "a"), into: &out)"#),

        // Step 2: conditionals, loops, forloop, else-if, nested structs, optionals.
        RenderCase(
            name: "feedFull",
            template: feedTemplate,
            call: #"feed(posts: [Post(title: "X<1>", slug: "x"), Post(title: "Y", slug: "y")], into: &out)"#),
        RenderCase(
            name: "feedEmpty",
            template: feedTemplate,
            call: #"feed(posts: [], into: &out)"#),
        RenderCase(
            name: "gradeB",
            template:
                "@component Grade(score: Int) {@if score >= 90 {A} else if score >= 80 {B} else {C}}",
            call: #"grade(score: 85, into: &out)"#),
        RenderCase(
            name: "byline",
            template: "@component Byline(article: Article) {<address>{article.author.name}</address>}",
            call: #"byline(article: Article(title: "t", author: User(name: "Ann & Co"), tags: []), into: &out)"#),
        RenderCase(
            name: "optionalNil",
            template: "@component Sub(subtitle: String?) {<p>{subtitle}</p>}",
            call: #"sub(subtitle: nil, into: &out)"#),
        RenderCase(
            name: "optionalSome",
            template: "@component Sub(subtitle: String?) {<p>{subtitle}</p>}",
            call: #"sub(subtitle: "A & B", into: &out)"#),

        // Step 3: component calls, slots, named slots, defaults.
        RenderCase(
            name: "cardWithSlots",
            template: cardTemplate,
            call: #"page(title: "T<x>", into: &out)"#),
        RenderCase(
            name: "cardFallback",
            template: cardTemplate,
            call: #"card(title: "Hi", into: &out)"#),
        RenderCase(
            name: "reorder",
            template:
                "@component Box(a: Int, b: Int) {<i>{a},{b}</i>}\n@component UseBox() {@Box(b: 2, a: 1)}",
            call: #"useBox(into: &out)"#),
        RenderCase(
            name: "positionalDefault",
            template:
                "@component Btn(label: String, kind: String = \"primary\") {<button class=\"{kind}\">{label}</button>}\n@component UseBtn() {@Btn(\"Go\")}",
            call: #"useBtn(into: &out)"#),

        // Step 4: Embedded-safe filters and methods.
        RenderCase(
            name: "filters",
            template:
                #"@component Stats(score: Int, ratio: Double, path: String, fallback: String?) {<a>{score | plus(10) | times(2)}</a><b>{ratio | round}</b><c>{ratio}</c><d>{fallback | default("n/a")}</d>@if path.hasPrefix("/admin"){<e>ok</e>}}"#,
            call: #"stats(score: 5, ratio: 3.5, path: "/admin/x", fallback: nil, into: &out)"#),
        RenderCase(
            name: "listContains",
            template:
                #"@component Has(tags: [String]) {@if tags.contains("swift") {yes} else {no}}"#,
            call: #"has(tags: ["swift", "go"], into: &out)"#),
        RenderCase(
            name: "stringEquality",
            template:
                #"@component Status(state: String) {@if state == "active" {<b>on</b>} else {<b>off</b>}}"#,
            call: #"status(state: "active", into: &out)"#),

        // Syntax Swiftification: ?? and @if let, identical to the renderer.
        RenderCase(
            name: "coalesceNil",
            template: #"@component Co(name: String?) {<p>{name ?? "Anon"}</p>}"#,
            call: #"co(name: nil, into: &out)"#),
        RenderCase(
            name: "coalesceSome",
            template: #"@component Co(name: String?) {<p>{name ?? "Anon"}</p>}"#,
            call: #"co(name: "Bob", into: &out)"#),
        RenderCase(
            name: "ifLetNil",
            template:
                #"@component Hello2(user: User?) {@if let u = user {<p>{u.name}</p>} else {<p>guest</p>}}"#,
            call: #"hello2(user: nil, into: &out)"#),
        RenderCase(
            name: "ifLetSome",
            template:
                #"@component Hello2(user: User?) {@if let u = user {<p>{u.name}</p>} else {<p>guest</p>}}"#,
            call: #"hello2(user: User(name: "Ann & Co"), into: &out)"#),
    ]

    static let feedTemplate =
        "@component Feed(posts: [Post]) {@if posts.size > 0 {<ul>@for post in posts {<li>{forloop.index}:{post.title}</li>}</ul>} else {<p>none</p>}}"

    static let cardTemplate =
        "@component Card(title: String) {<section><header>@slot(header){<h2>{title}</h2>}</header><div>@slot{<p>empty</p>}</div></section>}\n"
        + "@component Page(title: String) {@Card(title: title){<p>body</p>@content(header){<h1>{title}</h1>}}}"

    static let expected: [String: String] = [
        "greeting": "<p>Hello, Ann &amp; &lt;Bob&gt;!</p>",
        "raw": "<main><b>safe</b></main>",
        "member": "<h1>A &lt;Tag&gt;</h1>",
        "feedFull": "<ul><li>1:X&lt;1&gt;</li><li>2:Y</li></ul>",
        "feedEmpty": "<p>none</p>",
        "gradeB": "B",
        "byline": "<address>Ann &amp; Co</address>",
        "optionalNil": "<p></p>",
        "optionalSome": "<p>A &amp; B</p>",
        "cardWithSlots": "<section><header><h1>T&lt;x&gt;</h1></header><div><p>body</p></div></section>",
        "cardFallback": "<section><header><h2>Hi</h2></header><div><p>empty</p></div></section>",
        "reorder": "<i>1,2</i>",
        "positionalDefault": #"<button class="primary">Go</button>"#,
        "filters": "<a>30</a><b>4</b><c>3.5</c><d>n/a</d><e>ok</e>",
        "listContains": "yes",
        "stringEquality": "<b>on</b>",
        "coalesceNil": "<p>Anon</p>",
        "coalesceSome": "<p>Bob</p>",
        "ifLetNil": "<p>guest</p>",
        "ifLetSome": "<p>Ann &amp; Co</p>",
    ]

    @Test func rendersExpectedBytesNatively() throws {
        let rendered = try RenderHarness.render(
            cases: Self.cases, fixtures: Self.fixtures, target: .native)
        for (name, expected) in Self.expected {
            let bytes = try #require(rendered[name], "missing case \(name)")
            #expect(String(decoding: bytes, as: UTF8.self) == expected)
        }
    }

    @Test(.enabled(if: RenderHarness.embeddedToolchainAvailable()))
    func rendersExpectedBytesUnderEmbeddedWasm() throws {
        let rendered = try RenderHarness.render(
            cases: Self.cases, fixtures: Self.fixtures, target: .embeddedWasm)
        for (name, expected) in Self.expected {
            let bytes = try #require(rendered[name], "missing case \(name)")
            #expect(String(decoding: bytes, as: UTF8.self) == expected)
        }
    }

    // Scoped @style -> scope attributes; @state -> serialized hook.
    static let hookCase = RenderCase(
        name: "panel",
        template:
            "@component Panel(post: Post, open: Bool) {@style(scoped) {.p{color:red}}\n@state expanded = open\n<section class=\"p\">{post.title}</section>}",
        call: #"panel(post: Post(title: "A<B>", slug: "a"), open: true, into: &out)"#)

    func expectHooks(in html: String) {
        #expect(html.contains(#"data-plume-state>{"expanded":true}</script>"#))
        #expect(html.contains("<section data-plume-scope-plume-"))
        #expect(html.contains(#"class="p">A&lt;B&gt;</section>"#))
    }

    @Test func emitsStateAndScopeHooksNatively() throws {
        let rendered = try RenderHarness.render(
            cases: [Self.hookCase], fixtures: Self.fixtures, target: .native)
        expectHooks(in: String(decoding: try #require(rendered["panel"]), as: UTF8.self))
    }

    @Test(.enabled(if: RenderHarness.embeddedToolchainAvailable()))
    func emitsStateAndScopeHooksUnderEmbeddedWasm() throws {
        let rendered = try RenderHarness.render(
            cases: [Self.hookCase], fixtures: Self.fixtures, target: .embeddedWasm)
        expectHooks(in: String(decoding: try #require(rendered["panel"]), as: UTF8.self))
    }
}
