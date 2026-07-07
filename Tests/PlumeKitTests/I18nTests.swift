import Testing
import PlumeCore
import PlumeRuntime

@Suite struct I18nAmbientTests {
    let store = Translations(default: "en", [
        "en": ["welcome": "Welcome back", "greeting": "Hello, {name}"],
        "pt": ["welcome": "Bem-vindo de volta", "greeting": "Olá, {name}"],
    ])

    @Test func lookupParamsAndFallback() {
        #expect(store.t("welcome", locale: "pt") == "Bem-vindo de volta")
        #expect(store.t("greeting", locale: "en", ["name": "Ada"]) == "Hello, Ada")
        #expect(store.t("greeting", locale: "pt", ["name": "Ada"]) == "Olá, Ada")
        #expect(store.t("welcome", locale: "de") == "Welcome back")   // unknown locale → default
        #expect(store.t("missing.key", locale: "en") == "missing.key") // missing → key itself
        #expect(store.t("greeting", locale: "en") == "Hello, {name}")  // missing param left visible
    }

    @Test func ambientTAndUseLocaleOverride() {
        let state = LocalizationState(locale: "en") { key, loc, params in store.t(key, locale: loc, params) }
        RenderContext.$localization.withValue(state) {
            #expect(t("welcome") == "Welcome back")
            #expect(t("greeting", ["name": "Sam"]) == "Hello, Sam")
            useLocale("pt")                                  // app overrides (e.g. user preference)
            #expect(currentLocale == "pt")
            #expect(t("welcome") == "Bem-vindo de volta")
        }
    }

    @Test func negotiationFallsBackToConfiguredDefault() {
        var h = Headers(); h.set("accept-language", "de-DE,de;q=0.9")
        let req = Request(method: .get, path: "/", headers: h)
        #expect(req.preferredLanguage(available: ["en", "pt"], default: "pt") == "pt")   // no match → default
        var h2 = Headers(); h2.set("accept-language", "pt-BR,pt;q=0.9")
        let req2 = Request(method: .get, path: "/", headers: h2)
        #expect(req2.preferredLanguage(available: ["en", "pt"], default: "en") == "pt") // pt-BR → pt
    }
}

extension I18nAmbientTests {
    @Test func localeMatchingIsCaseInsensitive() {
        let store = Translations(default: "EN", ["en-US": ["hi": "Hello"], "pt": ["hi": "Olá"]])
        #expect(store.locales.contains("en-us"))          // normalized lowercase
        #expect(store.t("hi", locale: "en-US") == "Hello") // request casing matches
        #expect(store.defaultLocale == "en")               // default normalized too
        var h = Headers(); h.set("accept-language", "en-US,en;q=0.9")
        let req = Request(method: .get, path: "/", headers: h)
        #expect(req.preferredLanguage(available: store.locales, default: "pt") == "en-us")
    }
}
