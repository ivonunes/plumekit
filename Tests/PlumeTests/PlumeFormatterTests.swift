import XCTest

@testable import Plume

/// Behavioural tests for PlumeFormatter.format (the entry point behind
/// `plume format` and the language server's textDocument/formatting).
///
/// The formatter promises:
/// - line-based re-indentation of Plume block structure,
/// - verbatim (trimmed) preservation of every non-empty line, including the
///   contents of raw @style/@script/@navigation regions,
/// - collapsing of blank-line runs and exactly one trailing newline.
final class PlumeFormatterTests: XCTestCase {
    private let context: [String: Any] = [
        "site": ["title": "Inkstead", "url": "https://example.com"],
        "posts": [
            ["title": "Hello", "published": true],
            ["title": "Second", "published": false],
        ],
        "post": ["title": "Hello", "kind": "note", "featured": true, "hidden": false],
        "url": "https://example.com/",
        "label": "Read more",
    ]

    private static let fixtures: [(name: String, source: String)] = [
        (
            "nested if/for blocks",
            """
            @if site.title {
            <h1>{site.title}</h1>
            @for post in posts {
            <article>
            <h2>{post.title}</h2>
            </article>
            }
            }
            """
        ),
        (
            "else and else-if chains",
            """
            @if post.title {
            <h1>{post.title}</h1>
            } else if site.title {
            <h1>{site.title}</h1>
            } else {
            <h1>Untitled</h1>
            }
            """
        ),
        (
            "components with named slots and content blocks",
            """
            @component Card(title, tone = "plain") {
            <article class="card" class+="{tone}">
            <header>
            @slot("header") {
            <h2>{title}</h2>
            }
            </header>
            <div>@slot</div>
            </article>
            }
            @Card("Hello", tone: "bold") {
            @content(header) {
            <h1>Custom</h1>
            }
            <p>Body</p>
            }
            """
        ),
        (
            "embedded styles and scripts",
            """
            @style(scoped: true) {
            .grid {
            display: grid;
            }
            }
            @script {
            let menu = page.query("#menu")
            on ".toggle".click {
            menu.toggleClass("open")
            }
            }
            <div class="grid">{site.title}</div>
            """
        ),
        (
            "attribute helpers",
            """
            @if post.featured {
            <article class="card" class+="{post.kind}" class:featured="{post.featured}" hidden?="{post.hidden}">
            <a href="{url}" rel?="{post.rel}">{label}</a>
            </article>
            }
            """
        ),
        (
            "comments",
            """
            before
            @comment {
            it's a draft note { with braces }
            }
            after
            """
        ),
        (
            "navigation blocks",
            """
            @navigation(root: "main", viewTransitions: true) {
            on:beforeSwap {
            page.addClass("is-leaving")
            }
            }
            <main>{site.title}</main>
            """
        ),
        (
            "lets and long expressions",
            """
            @let currentPath = url.replace(site.url, "")
            @let isActive = currentPath == "/photos/" || currentPath.contains("/photos/") || post.kind == "photo-note"
            @if isActive {
            <a class="nav-link" class:active="{isActive}">{label}</a>
            }
            """
        ),
        (
            "inline css and json braces stay on one line",
            """
            <style>.card{color:red}.grid[data-state=open]{display:grid}</style>
            <script type="application/ld+json">{"@context":"https://schema.org","name":"{site.title}"}</script>
            """
        ),
        (
            "blank line runs",
            """
            <p>a</p>



            @if site.title {

            <p>{site.title}</p>


            }

            """
        ),
        (
            "already formatted source",
            """
            @if site.title {
              <h1>{site.title}</h1>
              @for post in posts {
                <article>{post.title}</article>
              }
            }
            """
        ),
        (
            "multi-line tags",
            """
            <a href="{url}"
            class="nav-link">{label}</a>
            """
        ),
    ]

    func testFormattingIsIdempotent() {
        for fixture in Self.fixtures {
            let once = PlumeFormatter.format(fixture.source)
            let twice = PlumeFormatter.format(once)
            XCTAssertEqual(twice, once, "Formatter is not idempotent for: \(fixture.name)")
        }
    }

    func testFormattingPreservesEveryContentLine() {
        for fixture in Self.fixtures {
            let original = trimmedContentLines(fixture.source)
            let formatted = trimmedContentLines(PlumeFormatter.format(fixture.source))
            XCTAssertEqual(
                formatted, original,
                "Formatter changed, dropped, or duplicated content for: \(fixture.name)")
        }
    }

    func testFormattingPreservesRenderedOutput() throws {
        for fixture in Self.fixtures {
            let original = try PlumeTemplate(fixture.source).render(context)
            let formatted = try PlumeTemplate(PlumeFormatter.format(fixture.source))
                .render(context)
            XCTAssertEqual(
                normalized(formatted), normalized(original),
                "Formatting changed render output for: \(fixture.name)")
        }
    }

    func testFormatsComponentInvocationAndContentBlocks() {
        let formatted = PlumeFormatter.format("""
        @Card("Hello", tone: "bold") {
        @content(header) {
        <h1>Custom</h1>
        }
        <p>Body</p>
        }
        """)

        XCTAssertEqual(formatted, """
        @Card("Hello", tone: "bold") {
          @content(header) {
            <h1>Custom</h1>
          }
          <p>Body</p>
        }
        """ + "\n")
    }

    func testAlreadyFormattedTemplateIsLeftUnchanged() {
        let source = """
        @if site.title {
          <h1>{site.title}</h1>
        }
        """ + "\n"
        XCTAssertEqual(PlumeFormatter.format(source), source)
    }

    func testCollapsesBlankLineRunsAndEndsWithSingleTrailingNewline() {
        let formatted = PlumeFormatter.format("<p>a</p>\n\n\n\n<p>b</p>\n\n\n")
        XCTAssertEqual(formatted, "<p>a</p>\n\n<p>b</p>\n")
    }

    func testSupportsCustomIndentUnits() {
        let formatted = PlumeFormatter.format("@if x {\n<p>y</p>\n}", indent: "\t")
        XCTAssertEqual(formatted, "@if x {\n\t<p>y</p>\n}\n")
    }

    // MARK: - Helpers

    private func trimmedContentLines(_ source: String) -> [String] {
        source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Collapses whitespace runs (formatting only moves whitespace around) and
    /// neutralises scoped style/script hashes, which intentionally depend on
    /// source positions.
    private func normalized(_ html: String) -> String {
        html
            .replacingOccurrences(
                of: #"data-plume-scope-plume-[0-9A-Za-z]+"#,
                with: "data-plume-scope",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
