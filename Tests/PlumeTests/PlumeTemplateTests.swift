import XCTest
@testable import Plume

final class PlumeTemplateTests: XCTestCase {
    func testRendersNativePlumeBlocksAndEscapesByDefault() throws {
        let template = try PlumeTemplate("""
        <h1>{site.title}</h1>
        @if posts.size > 0 {
        <ul>
        @for post in posts {
          <li class:note="{!post.title}">{post.title | default("Note")}</li>
        }
        </ul>
        }
        """)

        let html = try template.render([
            "site": ["title": "Ivo & Co"],
            "posts": [
                ["title": "Hello"],
                ["title": ""]
            ]
        ])

        XCTAssertTrue(html.contains("Ivo &amp; Co"))
        XCTAssertTrue(html.contains("<li>Hello</li>"))
        XCTAssertTrue(html.contains(#"<li class="note">Note</li>"#))
    }

    func testSupportsSwiftLikeExpressionsAndMethods() throws {
        let template = try PlumeTemplate("""
        @let currentPath = meta.canonicalUrl.replace(site.url, "")
        @let isPhotosActive = currentPath == "/photos/" || currentPath.contains("/photos/") || post.kind == "photo-note"
        <a class="nav-link" class:active="{isPhotosActive}">Photos</a>
        @for item in site.navigation {
          <span data-translate-value="{forloop.index | times(100)}%">{item.name}</span>
        }
        <time>{post.dateIso | date("d MMMM yyyy")}</time>
        """)

        let html = try template.render([
            "meta": [
                "canonicalUrl": "https://example.com/photos/"
            ],
            "site": [
                "url": "https://example.com",
                "navigation": [
                    ["name": "Photos"],
                    ["name": "Projects"]
                ]
            ],
            "post": [
                "kind": "article",
                "dateIso": "2026-05-10T18:30:00Z"
            ]
        ])

        XCTAssertTrue(html.contains(#"<a class="nav-link active">Photos</a>"#))
        XCTAssertTrue(html.contains(#"data-translate-value="100%""#))
        XCTAssertTrue(html.contains(#"data-translate-value="200%""#))
        XCTAssertTrue(html.contains("<time>10 May 2026</time>"))
    }

    func testSupportsCommonStringCollectionAndMathFilters() throws {
        let template = try PlumeTemplate("""
        {body | newlineToBR}
        {"/photos/a b.jpg" | urlEncode}
        {"one two three four" | truncateWords(3)}
        {10 | plus(5) | minus(3) | dividedBy(2) | modulo(4)}
        {-3.2 | abs | ceil}
        sorted={posts | sort("title") | map("title") | join(",")}
        published={posts | where("published", true) | map("title") | join("|")}
        unique={words | unique | reverse | join("-")}
        slice={"abcdef" | slice(1, 3)}
        json={jsonValue | json}
        """)

        let html = try template.render([
            "body": "Hello\nWorld",
            "posts": [
                ["title": "B", "published": true],
                ["title": "A", "published": false]
            ],
            "words": ["one", "two", "one"],
            "jsonValue": ["title": "A \"quoted\" title", "count": 2] as [String: Any]
        ])

        XCTAssertTrue(html.contains("Hello<br>\nWorld"))
        XCTAssertTrue(html.contains("%2Fphotos%2Fa%20b.jpg"))
        XCTAssertTrue(html.contains("one two three..."))
        XCTAssertTrue(html.contains("2"))
        XCTAssertTrue(html.contains("4"))
        XCTAssertTrue(html.contains("sorted=A,B"))
        XCTAssertTrue(html.contains("published=B"))
        XCTAssertTrue(html.contains("unique=two-one"))
        XCTAssertTrue(html.contains("slice=bcd"))
        XCTAssertTrue(html.contains(#"json={"count":2,"title":"A \"quoted\" title"}"#))
    }

    func testSupportsElseAndElseIfWithoutDirectiveMarkers() throws {
        let template = try PlumeTemplate("""
        @if post.title {
          <h1>{post.title}</h1>
        } else if site.title {
          <h1>{site.title}</h1>
        } else {
          <h1>Untitled</h1>
        }
        """)

        let fallback = try template.render([
            "post": ["title": ""],
            "site": ["title": "Fallback"]
        ])
        XCTAssertTrue(fallback.contains("<h1>Fallback</h1>"))

        let untitled = try template.render([
            "post": ["title": ""],
            "site": ["title": ""]
        ])
        XCTAssertTrue(untitled.contains("<h1>Untitled</h1>"))
    }

    func testSupportsOptionalAttributesAndRawOutput() throws {
        let template = try PlumeTemplate("""
        <a href="{url}" target?="{target}" rel?="{rel}">{label}</a>
        <article>{html | raw}</article>
        <rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><content:encoded>Body</content:encoded></rss>
        """)

        let html = try template.render([
            "url": "https://example.com/?a=1&b=2",
            "target": "_blank",
            "rel": "",
            "label": "<Read>",
            "html": "<p>Hello</p>"
        ])

        XCTAssertTrue(html.contains(#"href="https://example.com/?a=1&amp;b=2""#))
        XCTAssertTrue(html.contains(#"target="_blank""#))
        XCTAssertFalse(html.contains("rel="))
        XCTAssertTrue(html.contains("&lt;Read&gt;"))
        XCTAssertTrue(html.contains("<article><p>Hello</p></article>"))
        XCTAssertTrue(html.contains(#"xmlns:content="http://purl.org/rss/1.0/modules/content/""#))
        XCTAssertTrue(html.contains("<content:encoded>Body</content:encoded>"))
    }

    func testSafeHTMLRendersWithoutRawFilter() throws {
        let template = try PlumeTemplate("{trusted}{untrusted}")

        let html = try template.render([
            "trusted": PlumeSafeHTML("<p>Known HTML</p>"),
            "untrusted": "<script>alert(1)</script>"
        ])

        XCTAssertTrue(html.contains("<p>Known HTML</p>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testSupportsComponentsSlotsAndAttributeHelpers() throws {
        let template = try PlumeTemplate("""
        @component PostCard(post) {
        <article class="card" class+="{post.kind}" class:featured="{post.featured}" aria-current:page="{post.current}" hidden?="{post.hidden}">
          <h2>{post.title}</h2>
          <div>@slot</div>
        </article>
        }
        @PostCard(post) {
          <p>{post.excerpt}</p>
        }
        """)

        let html = try template.render([
            "post": [
                "kind": "note",
                "featured": true,
                "current": true,
                "hidden": false,
                "title": "Hello & Welcome",
                "excerpt": "Intro"
            ]
        ])

        XCTAssertTrue(html.contains(#"class="card featured note""#))
        XCTAssertTrue(html.contains(#"aria-current="page""#))
        XCTAssertFalse(html.contains("hidden"))
        XCTAssertTrue(html.contains("<h2>Hello &amp; Welcome</h2>"))
        XCTAssertTrue(html.contains("<div>\n  <p>Intro</p>\n</div>"))
    }

    func testSupportsNamedArgumentsDefaultValuesAndNamedSlots() throws {
        let template = try PlumeTemplate("""
        @component FeatureCard(title, tone = "plain", label = title) {
        <article class="feature-card" class+="{tone}">
          <header>
            @slot(name: "header") {
              <h2>{title}</h2>
            }
          </header>
          <div class="body">@slot</div>
          <footer>
            @slot("footer") {
              <small>{label}</small>
            }
          </footer>
        </article>
        }

        @FeatureCard("Hello", tone: "featured") {
          <p>Default slot</p>
        }

        @FeatureCard(title: "Named") {
          @content(header) {
            <h1>Custom header</h1>
          }
          <p>Named body</p>
          @content(footer) {
            <a href="/more/">More</a>
          }
        }
        """)

        let html = try template.render([:])

        XCTAssertTrue(html.contains(#"class="feature-card featured""#))
        XCTAssertTrue(html.contains("<h2>Hello</h2>"))
        XCTAssertTrue(html.contains("<p>Default slot</p>"))
        XCTAssertTrue(html.contains("<small>Hello</small>"))
        XCTAssertTrue(html.contains(#"class="feature-card plain""#))
        XCTAssertTrue(html.contains("<h1>Custom header</h1>"))
        XCTAssertTrue(html.contains("<p>Named body</p>"))
        XCTAssertTrue(html.contains(#"<a href="/more/">More</a>"#))
        XCTAssertFalse(html.contains("<h2>Named</h2>"))
    }

    func testRejectsUnknownComponentArguments() throws {
        let template = try PlumeTemplate("""
        @component Card(title) {
          <article>{title}</article>
        }
        @Card(name: "Hello")
        """)

        XCTAssertThrowsError(try template.render([:])) { error in
            XCTAssertTrue(String(describing: error).contains("Unknown argument name for component Card"))
        }
    }

    func testRejectsDuplicateComponentArguments() throws {
        let template = try PlumeTemplate("""
        @component Card(title, tone = "plain") {
          <article class="{tone}">{title}</article>
        }
        @Card("Hello", title: "Override")
        """)

        XCTAssertThrowsError(try template.render([:])) { error in
            XCTAssertTrue(String(describing: error).contains("Duplicate argument title for component Card"))
        }
    }

    func testSupportsInteractiveStateBindingsAndActions() throws {
        let template = try PlumeTemplate("""
        @state expanded = false
        <button on:click="{expanded.toggle()}" aria-expanded="{expanded}">{expanded ? "Hide" : "Show"}</button>
        <section hidden?="{!expanded}" class:open="{expanded}">Details</section>
        """)

        let result = try template.renderResult([:])

        XCTAssertTrue(result.requiresRuntime)
        XCTAssertEqual(result.state["expanded"] as? Bool, false)
        XCTAssertTrue(result.html.contains(#"data-plume-on-click="expanded.toggle()""#))
        XCTAssertTrue(result.html.contains(#"aria-expanded="false""#))
        XCTAssertTrue(result.html.contains(#"data-plume-bind-aria-expanded="expanded""#))
        XCTAssertTrue(result.html.contains(#"data-plume-text="expanded ? &quot;Hide&quot; : &quot;Show&quot;">Show</span>"#))
        XCTAssertTrue(result.html.contains(#"hidden data-plume-attr-hidden="!expanded""#))
        XCTAssertTrue(result.html.contains(#"data-plume-class-open="expanded""#))
    }

    func testSupportsBrowserActionsAndStyleBindings() throws {
        let template = try PlumeTemplate("""
        @state offset = "0"
        <nav style:--translate-main-slider="{offset}" on:mouseleave="{offset.set('0')}">
          <a on:mouseover="{offset.set('100%')}" on:click="{page.scrollToTop(smooth: true)}">Top</a>
        </nav>
        """)

        let result = try template.renderResult([:])

        XCTAssertTrue(result.requiresRuntime)
        XCTAssertEqual(result.state["offset"] as? String, "0")
        XCTAssertTrue(result.html.contains(#"style="--translate-main-slider: 0;""#))
        XCTAssertTrue(result.html.contains(#"data-plume-style---translate-main-slider="offset""#))
        XCTAssertTrue(result.html.contains(#"data-plume-on-mouseleave="offset.set('0')""#))
        XCTAssertTrue(result.html.contains(#"data-plume-on-mouseover="offset.set('100%')""#))
        XCTAssertTrue(result.html.contains(#"data-plume-on-click="page.scrollToTop(smooth: true)""#))
    }

    func testSupportsMeasurementActionsAndStyleTemplateBindings() throws {
        let template = try PlumeTemplate("""
        @state sliderX = 0
        @state sliderWidth = 0
        <nav on:resize="{page.measure('.active', into: ['sliderX', 'sliderWidth'])}">
          <a class="active" on:pointerenter="{page.measure(event.target, into: ['sliderX', 'sliderWidth'], round: true)}">Home</a>
          <span class="slider" style:--slider-x="{sliderX}px" style:--slider-width="{sliderWidth}px"></span>
        </nav>
        <section on:visible="{sliderX.set(10)}">Intro</section>
        """)

        let result = try template.renderResult([:])

        XCTAssertTrue(result.requiresRuntime)
        XCTAssertTrue(result.html.contains(#"data-plume-on-resize="page.measure('.active', into: ['sliderX', 'sliderWidth'])""#))
        XCTAssertTrue(result.html.contains(#"data-plume-on-pointerenter="page.measure(event.target, into: ['sliderX', 'sliderWidth'], round: true)""#))
        XCTAssertTrue(result.html.contains(#"--slider-x: 0px"#))
        XCTAssertTrue(result.html.contains(#"--slider-width: 0px"#))
        XCTAssertTrue(result.html.contains(#"data-plume-style-template---slider-x="{sliderX}px""#))
        XCTAssertTrue(result.html.contains(#"data-plume-style-template---slider-width="{sliderWidth}px""#))
        XCTAssertTrue(result.html.contains(#"data-plume-on-visible="sliderX.set(10)""#))
    }

    func testBrowserActionsRequireRuntimeWithoutState() throws {
        let template = try PlumeTemplate("""
        <button on:click="{page.scrollToTop(smooth: true)}">Top</button>
        """)

        let result = try template.renderResult([:])

        XCTAssertTrue(result.requiresRuntime)
        XCTAssertTrue(result.state.isEmpty)
        XCTAssertTrue(result.html.contains(#"data-plume-on-click="page.scrollToTop(smooth: true)""#))
    }

    func testSupportsDeclarativeNavigation() throws {
        let template = try PlumeTemplate("""
        @navigation(root: "main", viewTransitions: true, scroll: "top", minimumDuration: 250) {
          on:beforeSwap {
            page.addClass("is-leaving")
          }

          on:afterSwap {
            page.removeClass("is-leaving")
          }
        }
        <main>Content</main>
        """)

        let result = try template.renderResult([:])
        let navigation = try XCTUnwrap(result.navigation.first)

        XCTAssertTrue(result.requiresRuntime)
        XCTAssertEqual(navigation.root, "main")
        XCTAssertTrue(navigation.viewTransitions)
        XCTAssertEqual(navigation.scroll, "top")
        XCTAssertEqual(navigation.minimumDuration, 250)
        XCTAssertEqual(navigation.hooks, [
            PlumeNavigationHook(name: "beforeSwap", actions: [#"page.addClass("is-leaving")"#]),
            PlumeNavigationHook(name: "afterSwap", actions: [#"page.removeClass("is-leaving")"#])
        ])
        XCTAssertEqual(result.html.trimmingCharacters(in: .whitespacesAndNewlines), "<main>Content</main>")
    }

    func testSupportsTemplateFunctionsAndImageDirective() throws {
        let template = try PlumeTemplate("""
        <img src="{asset("images/avatar.png")}" alt="">
        <figure>@image("images/avatar.png", alt: site.author, class: "avatar")<figcaption>Avatar</figcaption></figure>
        """, sourceName: "/site/theme/home.plume")

        let result = try template.renderResult([
            "site": ["author": "Ivo"],
            "asset": PlumeFunction { call in
                let src = call.arguments.isEmpty ? "" : (call.arguments[0] as? String ?? "")
                return "/assets/\(src)"
            },
            "image": PlumeFunction { call in
                let src = call.arguments.isEmpty ? "" : (call.arguments[0] as? String ?? "")
                let alt = (call.namedArguments["alt"] ?? nil) as? String ?? ""
                let className = (call.namedArguments["class"] ?? nil) as? String ?? ""
                return PlumeSafeHTML(#"<img src="/assets/\#(src)" alt="\#(alt)" class="\#(className)">"#)
            }
        ])

        XCTAssertTrue(result.html.contains(#"<img src="/assets/images/avatar.png" alt="">"#))
        XCTAssertTrue(result.html.contains(#"<img src="/assets/images/avatar.png" alt="Ivo" class="avatar">"#))
        XCTAssertTrue(result.html.contains("<figcaption>Avatar</figcaption>"))
    }

    func testCollectsInlineFileAndScopedStylesAndScripts() throws {
        let template = try PlumeTemplate("""
        @style {
          .page { color: red; }
        }
        @style(file: "styles/site.css")
        @script(language: "javascript") {
          document.documentElement.dataset.ready = "true";
        }
        @script(file: "scripts/site.js")
        @component PhotoGrid(posts) {
          @style(scoped: true) {
            .grid { display: grid; }
            img:hover { opacity: 0.8; }
          }
          @script(scoped: true, language: "javascript") {
            root.dataset.ready = "true";
          }
          <ul class="grid">@for post in posts {<li><img src="{post.image}" alt=""></li>}</ul>
        }
        @PhotoGrid(posts)
        """, sourceName: "/site/theme/home.plume")

        let result = try template.renderResult([
            "posts": [["image": "/media/photo.jpg"]]
        ])

        XCTAssertEqual(result.styles.count, 3)
        XCTAssertEqual(result.styles[0].css?.trimmingCharacters(in: .whitespacesAndNewlines), ".page { color: red; }")
        XCTAssertEqual(result.styles[1].file, "styles/site.css")
        let scoped = try XCTUnwrap(result.styles.first { $0.scoped })
        XCTAssertNotNil(scoped.scope)
        XCTAssertTrue(result.html.contains("data-plume-scope-\(scoped.scope!)"))
        XCTAssertEqual(result.scripts.count, 3)
        XCTAssertEqual(result.scripts[0].js?.trimmingCharacters(in: .whitespacesAndNewlines), #"document.documentElement.dataset.ready = "true";"#)
        XCTAssertEqual(result.scripts[1].file, "scripts/site.js")
        let scopedScript = try XCTUnwrap(result.scripts.first { $0.scoped })
        XCTAssertNotNil(scopedScript.scope)
        XCTAssertTrue(result.html.contains("data-plume-scope-\(scopedScript.scope!)"))
        XCTAssertTrue(result.html.contains(#"<ul class="grid""#))
    }

    func testSupportsPlumeClientScriptLanguage() throws {
        let template = try PlumeTemplate("""
        @script {
          let menu = page.query("#menu")
          on ".toggle".click {
            event.preventDefault()
            menu.toggleClass("is-open", when: page.scrollY > 10)
            page.scrollTo(selector: "#main", smooth: true)
          }
        }
        @script(language: "javascript") {
          document.body.dataset.raw = "true";
        }
        """, sourceName: "theme/home.plume")

        let result = try template.renderResult([:])

        XCTAssertEqual(result.scripts.count, 2)
        XCTAssertEqual(result.scripts[0].language, .plume)
        XCTAssertEqual(result.scripts[1].language, .javascript)

        let js = try PlumeClientScriptCompiler.compile(result.scripts[0].js ?? "", sourceName: result.scripts[0].sourceName)
        XCTAssertTrue(js.contains(##"const menu = document.querySelector("#menu");"##))
        XCTAssertTrue(js.contains(#"for (const element of document.querySelectorAll(".toggle")) {"#))
        XCTAssertTrue(js.contains(#"event.preventDefault();"#))
        XCTAssertTrue(js.contains(#"(menu)?.classList.toggle("is-open", !!(window.scrollY > 10));"#))
        XCTAssertTrue(js.contains(##"document.querySelector("#main")?.scrollIntoView({ behavior: (true ? "smooth" : "auto")"##))
    }

    func testPlumeClientScriptDiagnosticsIncludeSourceContext() {
        XCTAssertThrowsError(try PlumeClientScriptCompiler.compile("""
        let menu = page.query("#menu")
        menu.fly()
        """, sourceName: "theme/home.plume")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unsupported Plume script method fly"))
            XCTAssertTrue(message.contains("theme/home.plume:2:1"))
            XCTAssertTrue(message.contains("menu.fly()"))
        }
    }

    func testSupportsPlumeBrowserRuntimeScripts() throws {
        let js = try PlumeClientScriptCompiler.compileBrowserRuntime("""
        func start() {
          let value = 1;
          document.documentElement.dataset.value = String(value);
        }
        start();
        """, sourceName: "runtime.plume")

        XCTAssertFalse(js.contains("@browserRuntime"))
        XCTAssertTrue(js.contains("function start() {"))
        XCTAssertTrue(js.contains("let value = 1;"))
        XCTAssertTrue(js.contains("document.documentElement.dataset.value = String(value);"))
    }

    func testBrowserRuntimeScriptsSupportSwiftLikeDeclarations() throws {
        let js = try PlumeClientScriptCompiler.compileBrowserRuntime("""
        class ForgejoAdapter: GitHubAdapter {
          init(config, token) {
            self.config = config;
            self.token = token;
          }
          async func validateConnection() {
            await self.request("/validate");
          }
        }
        func start() {
          return new ForgejoAdapter({}, "");
        }
        GitHubAdapter.prototype.readBlobSummary = async func(path, sha) {
          return await self.request(path);
        };
        let names = posts.map(func(post) {
          return post.title;
        });
        let loader = async func(path) {
          return await fetch(path);
        };
        """, sourceName: "runtime.plume")

        XCTAssertTrue(js.contains("class ForgejoAdapter extends GitHubAdapter {"))
        XCTAssertTrue(js.contains("constructor(config, token) {"))
        XCTAssertTrue(js.contains("this.config = config;"))
        XCTAssertTrue(js.contains("async validateConnection() {"))
        XCTAssertTrue(js.contains("await this.request(\"/validate\");"))
        XCTAssertTrue(js.contains("function start() {"))
        XCTAssertTrue(js.contains("GitHubAdapter.prototype.readBlobSummary = async function(path, sha) {"))
        XCTAssertTrue(js.contains("return await this.request(path);"))
        XCTAssertTrue(js.contains("let names = posts.map(function(post) {"))
        XCTAssertTrue(js.contains("let loader = async function(path) {"))
    }

    func testDiagnosticsIncludeSourceLineAndSuggestions() throws {
        let template = try PlumeTemplate("{site.title | upcas}", sourceName: "home.plume")

        XCTAssertThrowsError(try template.render(["site": ["title": "Inkstead"]])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unsupported Plume filter: upcas. Did you mean upcase?"))
            XCTAssertTrue(message.contains("home.plume:1:1"))
            XCTAssertTrue(message.contains("{site.title | upcas}"))
            XCTAssertTrue(message.contains("^"))
        }
    }

    func testFormatsPlumeBlocks() {
        let formatted = PlumeFormatter.format("""
        @if site.title {
        <h1>{site.title}</h1>
        @style(scoped: true) {
        .card {
        display: grid;
        }
        }
        @script(scoped: true) {
        root.addClass("ready")
        }
        @slot("header") {
        <h2>Fallback</h2>
        }
        @for post in posts {
        <article>{post.title}</article>
        }
        }
        """)

        XCTAssertEqual(formatted, """
        @if site.title {
          <h1>{site.title}</h1>
          @style(scoped: true) {
            .card {
            display: grid;
            }
          }
          @script(scoped: true) {
            root.addClass("ready")
          }
          @slot("header") {
            <h2>Fallback</h2>
          }
          @for post in posts {
            <article>{post.title}</article>
          }
        }
        """ + "\n")
    }

    func testFormatsElseIfBlocks() {
        let formatted = PlumeFormatter.format("""
        @if post.title {
        <h1>{post.title}</h1>
        } else if site.title {
        <h1>{site.title}</h1>
        } else {
        <h1>Untitled</h1>
        }
        """)

        XCTAssertEqual(formatted, """
        @if post.title {
          <h1>{post.title}</h1>
        } else if site.title {
          <h1>{site.title}</h1>
        } else {
          <h1>Untitled</h1>
        }
        """ + "\n")
    }

    func testLeavesCssAndJsonBracesAlone() throws {
        let template = try PlumeTemplate("""
        <style>.card{color:red}.grid[data-state=open]{display:grid}</style>
        <script type="application/ld+json">{"@context":"https://schema.org","name":"{site.title}"}</script>
        """)

        let html = try template.render(["site": ["title": "Ivo & Co"]])

        XCTAssertTrue(html.contains(".card{color:red}"))
        XCTAssertTrue(html.contains(#"{"@context":"https://schema.org""#))
        XCTAssertTrue(html.contains(#""name":"Ivo &amp; Co""#))
    }

    func testRejectsOldLiquidSyntaxAndUnknownFilters() throws {
        XCTAssertThrowsError(try PlumeTemplate("{{ site.title }}"))
        let template = try PlumeTemplate("{site.title | totallyUnknownFilter}")
        XCTAssertThrowsError(try template.render(["site": ["title": "Inkstead"]])) { error in
            XCTAssertTrue(String(describing: error).contains("totallyUnknownFilter"))
        }
    }
}
