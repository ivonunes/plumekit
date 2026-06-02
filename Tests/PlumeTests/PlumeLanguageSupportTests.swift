import XCTest
@testable import Plume

final class PlumeLanguageSupportTests: XCTestCase {
    func testDiagnosticsReportPlumeSyntaxErrorsWithLocation() {
        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: """
            @if site.title {
              <h1>{site.title}</h1>
            """,
            sourceName: "theme/home.plume"
        )

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.sourceName, "theme/home.plume")
        XCTAssertTrue(diagnostics.first?.message.contains("Missing closing }") == true)
    }

    func testDiagnosticsUseComponentSources() {
        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: """
            @Card("Hello", title: "Duplicate")
            """,
            sourceName: "theme/home.plume",
            componentSources: [
                "theme/components/Card.plume": """
                @component Card(title) {
                  <article>{title}</article>
                }
                """
            ]
        )

        XCTAssertEqual(diagnostics.first?.message, "Duplicate argument title for component Card.")
        XCTAssertEqual(diagnostics.first?.line, 1)
    }

    func testDiagnosticsCompileInlinePlumeScripts() {
        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: """
            @script {
              let menu = page.query("#menu")
              menu.fly()
            }
            """,
            sourceName: "theme/home.plume"
        )

        XCTAssertEqual(diagnostics.first?.message, "Unsupported Plume script method fly.")
        XCTAssertEqual(diagnostics.first?.line, 3)
    }

    func testCompletionsIncludeDirectivesAndContextValues() {
        let labels = Set(PlumeLanguageSupport.completions().map(\.label))

        XCTAssertTrue(labels.contains("@component"))
        XCTAssertTrue(labels.contains("@navigation"))
        XCTAssertTrue(labels.contains("site"))
        XCTAssertTrue(labels.contains("class:"))
    }

    func testDocumentSymbolsFindComponentsStateAndResources() {
        let symbols = PlumeLanguageSupport.symbols(in: """
        @component Card(title) {
          <article>{title}</article>
        }
        @state expanded = false
        @style(scoped) {
          .card { color: red; }
        }
        @script {
          expanded.toggle()
        }
        """)

        XCTAssertTrue(symbols.contains { $0.name == "Card" && $0.detail == "component" })
        XCTAssertTrue(symbols.contains { $0.name == "expanded" && $0.detail == "state" })
        XCTAssertTrue(symbols.contains { $0.name == "style" && $0.detail == "style" })
        XCTAssertTrue(symbols.contains { $0.name == "script" && $0.detail == "script" })
    }
}
