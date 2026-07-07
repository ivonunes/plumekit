//
//  PlumeAssetBundleTests.swift
//  PlumeTests — build-time asset bundle
//

import Foundation
import Testing

@testable import Plume

@Suite struct PlumeAssetBundleTests {
    @Test func scopedStyleIsRewrittenWithTheRendererScopeId() throws {
        let source = """
            @style(scoped) {
            .card { color: red; }
            }
            <div class="card">x</div>
            """
        // The interpreting renderer's scope id for this declaration…
        let rendered = try PlumeTemplate(source, sourceName: "Page.plume").renderResult([:])
        let scope = try #require(rendered.styles.first?.scope)
        #expect(rendered.html.contains("data-plume-scope-\(scope)"))

        // …must be the exact id the build-time bundle scopes the CSS with.
        let bundle = try PlumeAssetBundle.build(templates: ["Page.plume": source])
        #expect(bundle.css.contains(".card[data-plume-scope-\(scope)]"))
        #expect(!bundle.css.contains(".card {"))  // the bare selector was rewritten
    }

    @Test func unscopedStyleIsPassedThrough() throws {
        let source = "@style { body { margin: 0; } }"
        let bundle = try PlumeAssetBundle.build(templates: ["G.plume": source])
        #expect(bundle.css.contains("body { margin: 0; }"))
        #expect(!bundle.css.contains("data-plume-scope"))
    }

    @Test func javaScriptBundleIncludesRuntimeAndScripts() throws {
        let source = "@script(javascript) { window.demo = 1; }"
        let bundle = try PlumeAssetBundle.build(templates: ["S.plume": source])
        #expect(bundle.javaScript.contains("bootPlumeRuntime"))  // the client runtime
        #expect(bundle.javaScript.contains("Plume.apply"))  // the drive layer
        #expect(bundle.javaScript.contains("window.demo = 1;"))  // the page script
    }

    @Test func runtimeCanBeOmitted() throws {
        let bundle = try PlumeAssetBundle.build(
            templates: ["S.plume": "@script(javascript) { var x = 1; }"], includeRuntime: false)
        #expect(!bundle.javaScript.contains("bootPlumeRuntime"))
        #expect(bundle.javaScript.contains("var x = 1;"))
    }

    @Test func fileNamesAreContentHashedAndStable() throws {
        let a = try PlumeAssetBundle.build(templates: ["P.plume": "@style { a { color: red; } }"])
        let b = try PlumeAssetBundle.build(templates: ["P.plume": "@style { a { color: red; } }"])
        let c = try PlumeAssetBundle.build(templates: ["P.plume": "@style { a { color: blue; } }"])
        #expect(a.cssFileName == b.cssFileName)  // deterministic
        #expect(a.cssFileName != c.cssFileName)  // changes with content
        #expect(a.cssFileName.hasPrefix("app.") && a.cssFileName.hasSuffix(".css"))
        #expect(a.javaScriptFileName.hasPrefix("app.") && a.javaScriptFileName.hasSuffix(".js"))
    }

    @Test func writesHashedFilesToDisk() throws {
        let bundle = try PlumeAssetBundle.build(
            templates: ["P.plume": "@style(scoped) {\n.x { color: red; }\n}\n<p class=\"x\"></p>"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plume-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try bundle.write(to: directory)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let writtenCSS = try String(contentsOf: urls[0], encoding: .utf8)
        #expect(writtenCSS.contains("data-plume-scope-"))
    }
}
