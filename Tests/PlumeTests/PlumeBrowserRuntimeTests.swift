import XCTest
import Plume

final class PlumeBrowserRuntimeTests: XCTestCase {
    func testJavaScriptIsCompiledPlainJavaScript() {
        let js = PlumeBrowserRuntime.javaScript
        XCTAssertFalse(js.isEmpty)
        XCTAssertTrue(js.contains("function bootPlumeRuntime()"))
        XCTAssertTrue(js.contains("bootPlumeRuntime();"))
        // Compiled output, not the raw Plume client-script source.
        XCTAssertFalse(js.contains("@browserRuntime"))
        XCTAssertFalse(js.contains("func("))
        XCTAssertFalse(js.contains("func "))
        XCTAssertFalse(js.contains("=>"))
    }

    func testJavaScriptIsStableAcrossAccesses() {
        XCTAssertEqual(PlumeBrowserRuntime.javaScript, PlumeBrowserRuntime.javaScript)
    }

    func testJavaScriptReadsTheStateScriptTag() {
        let js = PlumeBrowserRuntime.javaScript
        XCTAssertTrue(js.contains(#"script[data-plume-state]"#))
        // A page with @navigation but no @state must still boot the runtime, so
        // the missing state hook cannot early-return out of bootPlumeRuntime.
        XCTAssertFalse(js.contains("if (!stateScript) return;"))
    }

    func testJavaScriptImplementsTheNavigationProgressBar() {
        let js = PlumeBrowserRuntime.javaScript
        // Public surface + injected, namespaced style with an app-overridable color.
        XCTAssertTrue(js.contains("Plume.progress"))
        XCTAssertTrue(js.contains("plume-progress-bar"))
        XCTAssertTrue(js.contains("--plume-progress-color"))
        // @navigation options wired through the emitted config JSON.
        XCTAssertTrue(js.contains("progressBar"))
        XCTAssertTrue(js.contains("progressBarDelay"))
    }

    func testJavaScriptHandlesEveryAttributeTheRendererChecksFor() {
        // `PlumeRenderResult.requiresRuntime` is driven by these attribute
        // names; the runtime must wire up each of them.
        let js = PlumeBrowserRuntime.javaScript
        for attribute in [
            "data-plume-text",
            "data-plume-class",
            "data-plume-class-",
            "data-plume-bind-",
            "data-plume-attr-",
            "data-plume-style-",
            "data-plume-style-template-",
            "data-plume-on-",
        ] {
            XCTAssertTrue(js.contains(attribute), "Runtime does not handle \(attribute)")
        }
    }

    func testJavaScriptHandlesNavigationAndViewportContract() {
        let js = PlumeBrowserRuntime.javaScript
        XCTAssertTrue(js.contains(#"script[data-plume-navigation]"#))
        XCTAssertTrue(js.contains("plume:navigate:"))
        XCTAssertTrue(js.contains("X-Plume-Navigation"))
        XCTAssertTrue(js.contains("popstate"))
        XCTAssertTrue(js.contains("startViewTransition"))
        XCTAssertTrue(js.contains("data-plume-on-visible"))
        XCTAssertTrue(js.contains("IntersectionObserver"))
        XCTAssertTrue(js.contains("getBoundingClientRect"))
    }

    func testRendererEmittedAttributesAreCoveredByTheRuntime() throws {
        let template = try PlumeTemplate("""
        @state open = false
        @state label = "Hello"
        <button on:click="{open.toggle()}" aria-expanded="{open}" class:active="{open}" style:--x="{label}" hidden?="{!open}">{label}</button>
        <nav on:resize="{page.measure('.active', into: ['x'])}" style:--w="{label}px"></nav>
        """)

        let result = try template.renderResult([:])
        XCTAssertTrue(result.requiresRuntime)

        var names: Set<String> = []
        var searchRange = result.html.startIndex..<result.html.endIndex
        while let range = result.html.range(
            of: #"data-plume-[A-Za-z0-9-]+"#, options: .regularExpression, range: searchRange)
        {
            names.insert(String(result.html[range]))
            searchRange = range.upperBound..<result.html.endIndex
        }
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.contains("data-plume-on-click"))
        XCTAssertTrue(names.contains("data-plume-text"))

        let js = PlumeBrowserRuntime.javaScript
        let exactNames: Set<String> = ["data-plume-text", "data-plume-class"]
        let prefixes = [
            "data-plume-on-",
            "data-plume-bind-",
            "data-plume-attr-",
            "data-plume-style-template-",
            "data-plume-style-",
            "data-plume-class-",
        ]
        for name in names {
            if exactNames.contains(name) {
                XCTAssertTrue(js.contains(name), "Runtime does not handle \(name)")
                continue
            }
            let prefix = prefixes.first { name.hasPrefix($0) }
            XCTAssertNotNil(prefix, "Renderer emitted \(name) which no runtime prefix covers")
            if let prefix {
                XCTAssertTrue(js.contains(prefix), "Runtime does not handle \(prefix)")
            }
        }
    }

    func testDriveRuntimeExposesPublicApiAndDriveContract() {
        // Behaviour is proven in the jsdom harness (PlumeClientRuntimeTests); this
        // pins the public surface and keeps the no-arrow-function invariant.
        let js = PlumeBrowserRuntime.javaScript
        XCTAssertTrue(js.contains("Plume.apply"))
        XCTAssertTrue(js.contains("Plume.visit"))
        XCTAssertTrue(js.contains("Plume.morph"))
        XCTAssertTrue(js.contains("plume-stream"))
        XCTAssertTrue(js.contains("plume-frame"))
        XCTAssertTrue(js.contains("X-Plume-Frame"))
        XCTAssertFalse(js.contains("=>"), "shipped runtime must avoid arrow functions")
    }

    func testJavaScriptImplementsStateActionsAndPageActions() {
        let js = PlumeBrowserRuntime.javaScript
        // State actions: name.toggle() / set() / increment() / decrement().
        XCTAssertTrue(js.contains("toggle|set|increment|decrement"))
        // Page actions.
        for action in ["addClass", "removeClass", "toggleClass", "measure", "scrollToTop", "scrollTo"] {
            XCTAssertTrue(js.contains(action), "Runtime does not implement page.\(action)")
        }
    }
}
