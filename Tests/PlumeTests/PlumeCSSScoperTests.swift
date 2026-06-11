import XCTest
import Plume

final class PlumeCSSScoperTests: XCTestCase {
    let attribute = "data-plume-scope-plume-0123456789abcdef"

    func testScopesSimpleRule() {
        let output = PlumeCSSScoper.scope(".card { display: grid; }", attribute: attribute)
        XCTAssertEqual(output, ".card[\(attribute)] { display: grid; }")
    }

    func testScopesLastCompoundOfDescendantSelectors() {
        let output = PlumeCSSScoper.scope(".card img { opacity: 0.8; }", attribute: attribute)
        XCTAssertEqual(output, ".card img[\(attribute)] { opacity: 0.8; }")
    }

    func testScopesSelectorLists() {
        let output = PlumeCSSScoper.scope("h1, .title a { color: red; }", attribute: attribute)
        XCTAssertEqual(output, "h1[\(attribute)], .title a[\(attribute)] { color: red; }")
    }

    func testInsertsAttributeBeforePseudoClasses() {
        let output = PlumeCSSScoper.scope(".card img:hover { opacity: 0.8; }", attribute: attribute)
        XCTAssertEqual(output, ".card img[\(attribute)]:hover { opacity: 0.8; }")
    }

    func testInsertsAttributeBeforeLeadingPseudoClass() {
        let output = PlumeCSSScoper.scope(":root { --x: 1; }", attribute: attribute)
        XCTAssertEqual(output, "[\(attribute)]:root { --x: 1; }")
    }

    func testInsertsAttributeBeforePseudoElements() {
        let output = PlumeCSSScoper.scope(#".card::before { content: ","; }"#, attribute: attribute)
        XCTAssertEqual(output, #".card[\#(attribute)]::before { content: ","; }"#)
    }

    func testInsertsAttributeBeforePseudoClassAndPseudoElement() {
        let output = PlumeCSSScoper.scope("a:hover::after { content: \"\"; }", attribute: attribute)
        XCTAssertEqual(output, "a[\(attribute)]:hover::after { content: \"\"; }")
    }

    func testKeepsFunctionalPseudoClassArgumentsIntact() {
        let output = PlumeCSSScoper.scope(".x:not(.a, .b) { color: red; }", attribute: attribute)
        XCTAssertEqual(output, ".x[\(attribute)]:not(.a, .b) { color: red; }")
    }

    func testAppendsAfterAttributeSelectors() {
        let output = PlumeCSSScoper.scope(#"a[href^="https"] { color: blue; }"#, attribute: attribute)
        XCTAssertEqual(output, #"a[href^="https"][\#(attribute)] { color: blue; }"#)
    }

    func testDoesNotSplitOnCommasInsideAttributeSelectorsOrQuotes() {
        let output = PlumeCSSScoper.scope(#"a[title="a,b"] { color: blue; }"#, attribute: attribute)
        XCTAssertEqual(output, #"a[title="a,b"][\#(attribute)] { color: blue; }"#)
    }

    func testScopesRulesInsideMediaQueries() {
        let css = """
        @media (min-width: 40rem) {
          .card { grid-template-columns: 1fr 1fr; }
        }
        """
        let output = PlumeCSSScoper.scope(css, attribute: attribute)
        XCTAssertTrue(output.contains("@media (min-width: 40rem)"))
        XCTAssertTrue(output.contains(".card[\(attribute)] { grid-template-columns: 1fr 1fr; }"))
    }

    func testScopesRulesInsideSupportsContainerAndLayer() {
        let css = """
        @supports (display: grid) {
          .a { display: grid; }
        }
        @container (min-width: 10rem) {
          .b { color: red; }
        }
        @layer theme {
          .c { color: blue; }
        }
        """
        let output = PlumeCSSScoper.scope(css, attribute: attribute)
        XCTAssertTrue(output.contains(".a[\(attribute)] { display: grid; }"))
        XCTAssertTrue(output.contains(".b[\(attribute)] { color: red; }"))
        XCTAssertTrue(output.contains(".c[\(attribute)] { color: blue; }"))
    }

    func testLeavesKeyframesUntouched() {
        let css = """
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
        """
        XCTAssertEqual(PlumeCSSScoper.scope(css, attribute: attribute), css)
    }

    func testLeavesFontFaceUntouched() {
        let css = """
        @font-face {
          font-family: "Plume Sans";
          src: url("plume-sans.woff2");
        }
        """
        XCTAssertEqual(PlumeCSSScoper.scope(css, attribute: attribute), css)
    }

    func testLeavesStandaloneImportIntact() {
        let css = "@import url(\"theme.css\");\n"
        XCTAssertEqual(PlumeCSSScoper.scope(css, attribute: attribute), css)
    }

    func testLeavesCommentsIntact() {
        let output = PlumeCSSScoper.scope("/* heading */ .card { color: red; }", attribute: attribute)
        XCTAssertEqual(output, "/* heading */ .card[\(attribute)] { color: red; }")
    }

    func testIgnoresBracesInsideComments() {
        let output = PlumeCSSScoper.scope("/* { } */ .a { color: red; }", attribute: attribute)
        XCTAssertEqual(output, "/* { } */ .a[\(attribute)] { color: red; }")
    }

    func testPreservesDeclarationsAndTrailingTextVerbatim() {
        let css = ".a { color: red; background: url(\"a{b}.png\"); }\n"
        let output = PlumeCSSScoper.scope(css, attribute: attribute)
        XCTAssertEqual(output, ".a[\(attribute)] { color: red; background: url(\"a{b}.png\"); }\n")
    }

    func testScopedComponentStylesheetMatchesRendererScopeAttribute() throws {
        // End-to-end parity with the renderer: scope a component stylesheet
        // with the exact attribute the renderer adds to the markup.
        let template = try PlumeTemplate("""
        @style(scoped: true) {
          .card { display: grid; }
          .card img:hover { opacity: 0.8; }
          @media (min-width: 40rem) {
            .card { grid-template-columns: 1fr 1fr; }
          }
        }
        <article class="card"><img src="/photo.jpg" alt=""></article>
        """, sourceName: "components/Card.plume")

        let result = try template.renderResult([:])
        let style = try XCTUnwrap(result.styles.first)
        XCTAssertTrue(style.scoped)
        let scopeAttribute = try XCTUnwrap(style.scopeAttribute)
        XCTAssertTrue(scopeAttribute.hasPrefix("data-plume-scope-plume-"))
        XCTAssertTrue(result.html.contains(scopeAttribute))

        let css = try XCTUnwrap(style.css)
        let scoped = PlumeCSSScoper.scope(css, attribute: scopeAttribute)
        XCTAssertTrue(scoped.contains(".card[\(scopeAttribute)]"))
        XCTAssertTrue(scoped.contains("img[\(scopeAttribute)]:hover"))
        XCTAssertTrue(scoped.contains("@media (min-width: 40rem)"))
        XCTAssertFalse(scoped.contains("grid-template-columns: 1fr 1fr;[\(scopeAttribute)]"))
    }
}
