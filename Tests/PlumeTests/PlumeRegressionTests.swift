import XCTest

@testable import Plume

final class PlumeRegressionTests: XCTestCase {
    func testRecursiveComponentsThrowInsteadOfCrashing() throws {
        let template = try PlumeTemplate("""
        @component Loop() {
          @Loop()
        }
        @Loop()
        """)

        XCTAssertThrowsError(try template.render([:])) { error in
            guard let plumeError = error as? PlumeError else {
                return XCTFail("Expected PlumeError, got \(error)")
            }
            XCTAssertTrue(plumeError.message.contains("Loop"))
            XCTAssertTrue(plumeError.message.contains("64"))
            XCTAssertNotNil(plumeError.context)
        }
    }

    func testEscapingIncludesSingleQuotes() throws {
        let template = try PlumeTemplate(#"<p title="{name}">{name}</p>"#)
        let html = try template.render(["name": "O'Brien & \"Co\" <em>"])

        XCTAssertTrue(html.contains("O&#39;Brien &amp; &quot;Co&quot; &lt;em&gt;"))
        XCTAssertFalse(html.contains("O'Brien"))
    }

    func testEscapeOnceKeepsExistingEntitiesAndEscapesSingleQuotes() throws {
        let template = try PlumeTemplate("{text | escape_once}")
        let html = try template.render(["text": "Fish &amp; Chips 'n' &#39; <em> & more"])

        XCTAssertTrue(html.contains("Fish &amp; Chips &#39;n&#39; &#39; &lt;em&gt; &amp; more"))
    }

    func testNumericDoesNotTrapOnHugeDoubles() throws {
        let template = try PlumeTemplate("{big | plus(1)}")

        XCTAssertNoThrow(try template.render(["big": 1e19]))
        XCTAssertNoThrow(try template.render(["big": Double.greatestFiniteMagnitude]))
    }

    func testQuotedLiteralsRequireClosingQuoteAtEnd() throws {
        XCTAssertEqual(try PlumeTemplate(#"{"a" == "b"}"#).render([:]), "false")
        XCTAssertEqual(try PlumeTemplate(#"{"a" == "a"}"#).render([:]), "true")
        XCTAssertEqual(try PlumeTemplate(#"{"hello"}"#).render([:]), "hello")
    }

    func testEqualityComparesNumbersNumerically() throws {
        XCTAssertEqual(try PlumeTemplate("{1 == 1.0}").render([:]), "true")
        XCTAssertEqual(try PlumeTemplate("{1 != 1.0}").render([:]), "false")
        XCTAssertEqual(try PlumeTemplate("{count == 10}").render(["count": 10.0]), "true")
        XCTAssertEqual(try PlumeTemplate("{1 == 2}").render([:]), "false")
        XCTAssertEqual(try PlumeTemplate(#"{name == "x"}"#).render(["name": "x"]), "true")
    }

    func testCommentsAllowUnbalancedQuotes() throws {
        let template = try PlumeTemplate("""
        before
        @comment { it's a note }
        after
        """)
        let html = try template.render([:])

        XCTAssertTrue(html.contains("before"))
        XCTAssertTrue(html.contains("after"))
        XCTAssertFalse(html.contains("note"))
    }

    func testDefaultFilterKeepsZero() throws {
        let template = try PlumeTemplate("{count | default(5)}")

        XCTAssertEqual(try template.render(["count": 0]), "0")
        XCTAssertEqual(try template.render(["count": 0.0]), "0.0")
        XCTAssertEqual(try template.render([:]), "5")
        XCTAssertEqual(try template.render(["count": ""]), "5")
        XCTAssertEqual(try template.render(["count": false]), "5")
        XCTAssertEqual(try template.render(["count": [Any]()]), "5")

        let json = #"{"zero": 0, "flag": false}"#.data(using: .utf8)!
        let context = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(try PlumeTemplate("{zero | default(5)}").render(context), "0")
        XCTAssertEqual(try PlumeTemplate("{flag | default(5)}").render(context), "5")
    }

    func testAttributeHelpersHandleGreaterThanInsideQuotedValues() throws {
        let template = try PlumeTemplate("""
        <div data-arrow="a > b" class:on="{visible}">x</div>
        """)
        let html = try template.render(["visible": true])

        XCTAssertTrue(html.contains(#"data-arrow="a > b""#))
        XCTAssertTrue(html.contains(#"class="on""#))
    }

    func testNamespacedAttributesAreNotTreatedAsConditional() throws {
        let template = try PlumeTemplate("""
        <section epub:type="chapter" xlink:href="#top" xmlns:epub="http://www.idpf.org/2007/ops">x</section>
        """)
        let html = try template.render([:])

        XCTAssertTrue(html.contains(#"epub:type="chapter""#))
        XCTAssertTrue(html.contains("xlink:href=\"#top\""))
        XCTAssertTrue(html.contains(#"xmlns:epub="http://www.idpf.org/2007/ops""#))
    }

    func testSourceContextReportsLineAndColumn() {
        let parser = PlumeParser("first line\nsecond line\nthird line", sourceName: "test.plume")
        var location = parser.source.startIndex
        var expectedLine = 1
        var expectedColumn = 1
        while true {
            let context = parser.sourceContext(at: location)
            XCTAssertEqual(context.line, expectedLine)
            XCTAssertEqual(context.column, expectedColumn)
            guard location < parser.source.endIndex else { break }
            if parser.source[location] == "\n" {
                expectedLine += 1
                expectedColumn = 1
            } else {
                expectedColumn += 1
            }
            location = parser.source.index(after: location)
        }
        XCTAssertEqual(parser.sourceContext(at: parser.source.startIndex).sourceLine, "first line")

        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: "<h1>x</h1>\n<p>y</p>\n@if broken {",
            sourceName: "theme/home.plume"
        )
        XCTAssertEqual(diagnostics.first?.line, 3)
    }

    func testScanningHelpersPreserveCallSiteBehaviour() {
        XCTAssertEqual(
            PlumeScanning.splitExpression(
                "a || b | upcase", separator: "|", skippingLogicalPipes: true),
            ["a || b", "upcase"])
        XCTAssertEqual(
            PlumeScanning.splitExpression("a || b", separator: "|"),
            ["a", "", "b"])
        XCTAssertEqual(
            PlumeScanning.splitExpression(#"f("x,y"), [1, 2], z"#, separator: ","),
            [#"f("x,y")"#, "[1, 2]", "z"])
        XCTAssertNil(PlumeScanning.topLevelIndex(of: ":", in: #""a:b""#))
        XCTAssertNotNil(PlumeScanning.topLevelIndex(of: ":", in: #"label: value"#))
        XCTAssertEqual(PlumeScanning.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(
            PlumeScanning.suggestion(for: "defalut", in: ["default", "date"]),
            " Did you mean default?")
        XCTAssertEqual(PlumeScanning.suggestion(for: "x", in: []), "")
    }

    func testEnvironmentDiagnosticsUseSharedComponentTable() {
        let environment = PlumeLanguageSupport.environment(componentSources: [
            "components/Card.plume": """
            @component Card(title) {
              <article>{title}</article>
            }
            """,
            "components/Broken.plume": "@if broken {",
        ])

        let valid = PlumeLanguageSupport.diagnostics(
            for: #"@Card(title: "Hi")"#,
            sourceName: "home.plume",
            environment: environment
        )
        XCTAssertEqual(valid, [])

        let unknownArgument = PlumeLanguageSupport.diagnostics(
            for: #"@Card(heading: "Hi")"#,
            sourceName: "home.plume",
            environment: environment
        )
        XCTAssertEqual(unknownArgument.count, 1)
        XCTAssertTrue(unknownArgument.first?.message.contains("Unknown argument heading") == true)

        let broken = PlumeLanguageSupport.diagnostics(
            for: "@if broken {",
            sourceName: "components/Broken.plume",
            environment: environment
        )
        XCTAssertEqual(broken.count, 1)
        XCTAssertTrue(broken.first?.message.contains("Missing closing }") == true)
    }
}
