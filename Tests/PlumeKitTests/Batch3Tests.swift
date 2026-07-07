import Testing
import PlumeCore
import PlumeServer
import PlumeORM

@Suite struct SignedURLTests {
    let key = Array("test-signing-key".utf8)

    private func request(for signedURL: String) -> Request {
        let parts = signedURL.split(separator: "?", maxSplits: 1)
        return Request(method: .get, path: String(parts[0]),
                       query: parts.count > 1 ? String(parts[1]) : "",
                       headers: Headers(), body: [], context: .empty)
    }

    @Test func roundTripsAndRejectsTampering() {
        let url = SignedURL.sign("/unsubscribe?user=42", key: key)
        #expect(SignedURL.verify(request(for: url), key: key, nowEpochSeconds: 1000))

        // Change the covered parameter → invalid; wrong key → invalid.
        let tampered = url.replacingOccurrences(of: "user=42", with: "user=43")
        #expect(!SignedURL.verify(request(for: tampered), key: key, nowEpochSeconds: 1000))
        #expect(!SignedURL.verify(request(for: url), key: Array("other-key".utf8), nowEpochSeconds: 1000))
        #expect(!SignedURL.verify(request(for: "/unsubscribe?user=42"), key: key, nowEpochSeconds: 1000))
    }

    @Test func honorsExpiry() {
        let url = SignedURL.sign("/download/report.pdf", key: key, expiresAt: 5000)
        #expect(SignedURL.verify(request(for: url), key: key, nowEpochSeconds: 4999))
        #expect(!SignedURL.verify(request(for: url), key: key, nowEpochSeconds: 5001))

        // The expiry itself is covered by the signature — it can't be extended.
        let extended = url.replacingOccurrences(of: "sig_exp=5000", with: "sig_exp=9000")
        #expect(!SignedURL.verify(request(for: extended), key: key, nowEpochSeconds: 5001))
    }
}

@Suite struct I18nTests {
    let translations = Translations(default: "en", [
        "en": ["welcome.title": "Welcome back", "nav.posts": "Posts"],
        "pt": ["welcome.title": "Bem-vindo de volta"],
    ])

    private func request(acceptLanguage: String?) -> Request {
        var headers = Headers()
        if let acceptLanguage { headers.add("accept-language", acceptLanguage) }
        return Request(method: .get, path: "/", query: "", headers: headers, body: [], context: .empty)
    }

    @Test func looksUpWithFallbackChain() {
        #expect(translations.t("welcome.title", locale: "pt") == "Bem-vindo de volta")
        #expect(translations.t("nav.posts", locale: "pt") == "Posts")          // default-locale fallback
        #expect(translations.t("missing.key", locale: "pt") == "missing.key")  // key fallback
    }

    @Test func negotiatesTheRequestLanguage() {
        #expect(request(acceptLanguage: "pt-BR,pt;q=0.9,en;q=0.8")
            .preferredLanguage(available: ["en", "pt"]) == "pt")               // prefix match pt-BR → pt
        #expect(request(acceptLanguage: "fr-FR, fr;q=0.9")
            .preferredLanguage(available: ["en", "pt"]) == "en")               // no match → first available
        #expect(request(acceptLanguage: nil)
            .preferredLanguage(available: ["en", "pt"]) == "en")               // no header → first available
        #expect(request(acceptLanguage: "en-US,en;q=0.5")
            .preferredLanguage(available: ["pt", "en"]) == "en")
    }
}

@Suite struct JSONRepresentableTests {
    @Model final class Gadget: Model {
        var id: Int
        var name: String
        var secretNotes = "internal"   // deliberately NOT exposed by the transformer
    }

    @Test func transformerControlsTheWireShape() async throws {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Gadget.createTable(in: db)
        let one = Gadget(name: "widget"); _ = try await one.save(in: db)
        let two = Gadget(name: "sprocket"); _ = try await two.save(in: db)

        let single = String(decoding: Response.json(one).body, as: UTF8.self)
        #expect(single.contains("\"name\":\"widget\""))
        #expect(!single.contains("secretNotes") && !single.contains("internal"))

        let list = String(decoding: Response.json([one, two]).body, as: UTF8.self)
        #expect(list.hasPrefix("[") && list.contains("sprocket"))

        let page = try await Gadget.all().order(by: Gadget.id).paginate(limit: 1, in: db)
        let paged = String(decoding: Response.json(page).body, as: UTF8.self)
        #expect(paged.contains("\"hasMore\":true") && paged.contains("\"limit\":1"))
    }
}

extension JSONRepresentableTests.Gadget: JSONRepresentable {
    var jsonValue: JSONValue {
        .object([("id", .int(Int64(id))), ("name", .string(name))])
    }
}
