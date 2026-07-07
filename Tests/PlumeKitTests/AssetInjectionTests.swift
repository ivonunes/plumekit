import Testing
import PlumeRuntime

@Suite struct AssetInjectionTests {
    private func page(head: String = "", body: String = "") -> HTML {
        var out = HTML()
        out.raw("<!doctype html><html><head>\(head)</head><body>\(body)</body></html>")
        return out
    }

    @Test func splicesBothTagsIntoTheHead() {
        var out = page(head: "<title>t</title>", body: "<p>hi</p>")
        out.requireStylesheet("/app.abc123.css")
        out.requireScript("/app.def456.js")
        out.injectRequiredAssets()
        let html = String(decoding: out.bytes, as: UTF8.self)

        #expect(html.contains("<head><link rel=\"stylesheet\" data-plume-track href=\"/app.abc123.css\">"
            + "<script defer data-plume-track src=\"/app.def456.js\"></script><title>t</title></head>"))
    }

    @Test func linkLandsInHeadEvenWhenRequiredMidBody() {
        // Simulates a page whose only @style lives in a body component: the
        // requirement is recorded during body rendering, the splice still targets <head>.
        var out = HTML()
        out.raw("<!doctype html><html><head><title>t</title></head><body>")
        out.requireStylesheet("/app.abc.css")   // recorded mid-render
        out.raw("<div>styled content</div></body></html>")
        out.injectRequiredAssets()
        let html = String(decoding: out.bytes, as: UTF8.self)

        #expect(html.contains("<head><link rel=\"stylesheet\" data-plume-track href=\"/app.abc.css\"><title>t</title></head>"))
        #expect(!html.contains("body><link"))
    }

    @Test func fragmentsWithoutAHeadAreUntouched() {
        var out = HTML()
        out.raw("<li>new row</li>")
        out.requireStylesheet("/app.abc.css")
        out.injectRequiredAssets()
        #expect(String(decoding: out.bytes, as: UTF8.self) == "<li>new row</li>")
    }

    @Test func headerElementIsNotMistakenForHead() {
        var out = HTML()
        out.raw("<header>nav</header><p>fragment</p>")
        out.requireScript("/app.js")
        out.injectRequiredAssets()
        #expect(String(decoding: out.bytes, as: UTF8.self) == "<header>nav</header><p>fragment</p>")
    }

    @Test func injectionHappensOnceAndOnlyWhenRequired() {
        var plain = page(head: "<title>t</title>")
        plain.injectRequiredAssets()   // nothing required → untouched
        #expect(!String(decoding: plain.bytes, as: UTF8.self).contains("data-plume-track"))

        var out = page()
        out.requireStylesheet("/app.a.css")
        out.requireStylesheet("/app.b.css")   // first requirement wins
        out.injectRequiredAssets()
        out.injectRequiredAssets()            // second call is a no-op
        let html = String(decoding: out.bytes, as: UTF8.self)
        #expect(html.components(separatedBy: "data-plume-track").count == 2)   // exactly one tag
        #expect(html.contains("/app.a.css") && !html.contains("/app.b.css"))
    }

    @Test func headWithAttributesIsHandled() {
        var out = HTML()
        out.raw("<html><head lang=\"en\"><title>t</title></head><body></body></html>")
        out.requireScript("/app.js")
        out.injectRequiredAssets()
        #expect(String(decoding: out.bytes, as: UTF8.self)
            .contains("<head lang=\"en\"><script defer data-plume-track src=\"/app.js\"></script>"))
    }
}
