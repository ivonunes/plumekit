import XCTest

@testable import Plume

/// Tests for the Plume client-script compiler (the @script language seam):
/// PlumeClientScriptCompiler.compile / compileBrowserRuntime. Assertions are
/// on key substrings of the emitted JavaScript, not byte-exact output.
final class PlumeClientScriptTests: XCTestCase {
    func testCompilesDeclarationsEventsAndDomMethods() throws {
        let js = try PlumeClientScriptCompiler.compile("""
        let menu = page.query("#menu")
        var open = false
        on "#toggle".click {
          event.preventDefault()
          open = !open
          menu.toggleClass("is-open", when: open)
          menu.setText(open ? "Close" : "Menu")
        }
        on page.scroll {
          page.addClass("scrolled")
        }
        """, sourceName: "scripts/menu.plume")

        XCTAssertTrue(js.contains(##"const menu = document.querySelector("#menu");"##))
        XCTAssertTrue(js.contains("let open = false;"))
        XCTAssertTrue(js.contains(##"for (const element of document.querySelectorAll("#toggle")) {"##))
        XCTAssertTrue(js.contains(#"element.addEventListener("click", function(event) {"#))
        XCTAssertTrue(js.contains("event.preventDefault();"))
        XCTAssertTrue(js.contains("open = !open;"))
        XCTAssertTrue(js.contains(#"(menu)?.classList.toggle("is-open", !!(open));"#))
        // Ternary expressions survive into the compiled output, parenthesized so the
        // appended `?? ""` coercion applies to the whole expression.
        XCTAssertTrue(js.contains(#"(menu).textContent = String((open ? "Close" : "Menu"#))
        XCTAssertTrue(js.contains(#"window.addEventListener("scroll", function(event) {"#))
        XCTAssertTrue(
            js.contains(#"(document.documentElement)?.classList.add(...__plumeClasses("scrolled"));"#))
        // The class helper is emitted exactly once, at the top.
        XCTAssertTrue(js.hasPrefix("function __plumeClasses(value)"))
        XCTAssertEqual(js.components(separatedBy: "function __plumeClasses").count, 2)
    }

    func testCoercionParenthesizesLogicalExpressions() throws {
        let js = try PlumeClientScriptCompiler.compile("""
        let label = page.query("#label")
        var primary = ""
        var fallback = "Untitled"
        on "#refresh".click {
          label.setText(primary || fallback)
        }
        """, sourceName: "scripts/label.plume")

        // `String(primary || fallback ?? "")` would be a JavaScript SyntaxError:
        // mixing || with ?? requires parentheses.
        XCTAssertTrue(js.contains(#"(label).textContent = String((primary || fallback) ?? "");"#))
        XCTAssertFalse(js.contains(#"|| fallback ?? "#))
    }

    func testCompilesControlFlowLoopsAndElementMethods() throws {
        let js = try PlumeClientScriptCompiler.compile("""
        let field = page.query("#email")
        field.setAttribute("aria-invalid", "true")
        field.setStyle("--outline", "red")
        field.focus()
        for item in page.queryAll(".card") {
          if item.hidden {
            item.removeClass("ready")
          } else {
            item.addClass("ready")
          }
        }
        """, sourceName: "scripts/cards.plume")

        XCTAssertTrue(js.contains(#"if ((field)) (field).setAttribute("aria-invalid", String(("true") ?? ""));"#))
        XCTAssertTrue(js.contains(#"(field)?.style.setProperty("--outline", String(("red") ?? ""));"#))
        XCTAssertTrue(js.contains("(field)?.focus();"))
        XCTAssertTrue(
            js.contains(#"for (const item of Array.from(document.querySelectorAll(".card"))) {"#))
        XCTAssertTrue(js.contains("if (item.hidden) {"))
        XCTAssertTrue(js.contains("} else {"))
        XCTAssertTrue(js.contains(#"(item)?.classList.remove(...__plumeClasses("ready"));"#))
        XCTAssertTrue(js.contains(#"(item)?.classList.add(...__plumeClasses("ready"));"#))
    }

    func testCompilesExpressionFormsAndPageMethods() throws {
        let js = try PlumeClientScriptCompiler.compile("""
        let items = page.queryAll(".item")
        let width = page.width
        let label = page.scrollY > 10 ? "far" : "near"
        on page.ready {
          page.scrollTo(selector: "#main", smooth: true)
          page.scrollToTop(smooth: page.scrollY > 100)
        }
        on "input".input {
          page.toggleClass("typing", when: event.value)
        }
        """, sourceName: "scripts/page.plume")

        XCTAssertTrue(js.contains(#"const items = Array.from(document.querySelectorAll(".item"));"#))
        XCTAssertTrue(js.contains("const width = window.innerWidth;"))
        XCTAssertTrue(js.contains(#"const label = window.scrollY > 10 ? "far" : "near";"#))
        XCTAssertTrue(js.contains(#"document.addEventListener("DOMContentLoaded", function(event) {"#))
        XCTAssertTrue(js.contains(
            ##"document.querySelector("#main")?.scrollIntoView({ behavior: (true ? "smooth" : "auto"), block: "start", inline: "nearest" });"##))
        XCTAssertTrue(js.contains(
            #"window.scrollTo({ top: 0, behavior: (window.scrollY > 100 ? "smooth" : "auto") });"#))
        XCTAssertTrue(js.contains(
            #"(document.documentElement)?.classList.toggle("typing", !!(event?.target?.value));"#))
    }

    func testUnsupportedSyntaxProducesDiagnosticsNotCrashes() {
        XCTAssertThrowsError(
            try PlumeClientScriptCompiler.compile("delete window.x", sourceName: "s.plume")
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("Unsupported Plume script statement"))
        }

        XCTAssertThrowsError(
            try PlumeClientScriptCompiler.compile(#"console.log("hi")"#, sourceName: "s.plume")
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unsupported Plume script method log"))
            XCTAssertTrue(message.contains("s.plume:1:1"), "diagnostics carry source locations")
        }

        XCTAssertThrowsError(
            try PlumeClientScriptCompiler.compile("page.fly()", sourceName: "s.plume")
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Unsupported page method fly"))
        }
    }

    func testMalformedBlocksAndDeclarationsProduceDiagnostics() {
        let failures: [(source: String, message: String)] = [
            ("on \".t\".click {", "Missing closing } in @script block"),
            ("}", "Unexpected } in Plume script"),
            ("} else {", "Plume script else can only follow an if block"),
            ("let broken", "Plume script let declarations need a value"),
            ("if  {", "Plume script if blocks need a condition"),
            ("for thing {", "Plume script for loops use"),
            ("on toggle {", "Plume script events use"),
        ]
        for failure in failures {
            XCTAssertThrowsError(
                try PlumeClientScriptCompiler.compile(failure.source, sourceName: "s.plume"),
                "Expected \(failure.source) to throw"
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(failure.message),
                    "Expected \(failure.source) to report \(failure.message), got \(error)")
            }
        }
    }

    func testTemplateDiagnosticsSurfaceClientScriptErrors() {
        let diagnostics = PlumeLanguageSupport.diagnostics(
            for: """
            <main>ok</main>
            @script {
              menu.fly()
            }
            """,
            sourceName: "theme/home.plume"
        )

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(
            diagnostics.first?.message.contains("Unsupported Plume script method fly"), true)
        let line = diagnostics.first?.line ?? 0
        XCTAssertGreaterThan(line, 1, "embedded script errors are offset into the template")
    }

    func testBrowserRuntimeCompilationKeepsExpressionForms() throws {
        let js = try PlumeClientScriptCompiler.compileBrowserRuntime("""
        func choose(flag) {
          return flag ? "yes" : "no";
        }
        let result = choose(true);
        """, sourceName: "runtime.plume")

        XCTAssertTrue(js.contains("function choose(flag) {"))
        XCTAssertTrue(js.contains(#"return flag ? "yes" : "no";"#))
        XCTAssertTrue(js.contains("let result = choose(true);"))
    }
}
