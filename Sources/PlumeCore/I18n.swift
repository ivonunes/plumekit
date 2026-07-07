// Localization — a small, honest translations store. Translations are Swift data
// compiled into the app (no file parsing, no ICU — Embedded-clean by construction),
// looked up by key with a default-locale fallback:
//
//     let t = Translations(default: "en", [
//         "en": ["welcome.title": "Welcome back", "nav.posts": "Posts"],
//         "pt": ["welcome.title": "Bem-vindo de volta", "nav.posts": "Artigos"],
//     ])
//
//     let locale = request.preferredLanguage(available: ["en", "pt"])   // "pt"
//     t.t("welcome.title", locale: locale)                              // "Bem-vindo…"
//
// Lookup order: requested locale → default locale → the key itself (a missing
// translation renders visibly instead of crashing). For plural rules or dates,
// branch in the template/handler — this deliberately isn't ICU.

/// ASCII-lowercase a locale tag (BCP 47 tags are case-insensitive), byte-wise so it
/// links in the guest.
func normalizeLocale(_ locale: String) -> String {
    var bytes = Array(locale.utf8)
    for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] += 32 }
    return String(decoding: bytes, as: UTF8.self)
}

/// Byte-wise `<` for locale tags (no Unicode `String <`, which doesn't link in the guest).
func asciiLess(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var i = 0
    while i < x.count, i < y.count {
        if x[i] != y[i] { return x[i] < y[i] }
        i += 1
    }
    return x.count < y.count
}

public struct Translations: Sendable {
    public let defaultLocale: String
    private let tables: [(locale: String, entries: [(key: String, value: String)])]

    public init(default defaultLocale: String, _ tables: [String: [String: String]]) {
        // Locale tags are case-insensitive (BCP 47); normalise to lowercase so an
        // `en-US.json` file matches a request's `en-US`. Sort by locale so `locales`
        // and the negotiation order are deterministic (the input is a Dictionary).
        self.defaultLocale = normalizeLocale(defaultLocale)
        self.tables = tables
            .map { locale, entries in
                (locale: normalizeLocale(locale), entries: entries.map { ($0.key, $0.value) })
            }
            .sorted { asciiLess($0.locale, $1.locale) }
    }

    /// The languages this store has, for content negotiation.
    /// (A closure, not a key path — key paths don't compile in Embedded Swift.)
    public var locales: [String] { tables.map { $0.locale } }

    /// A locale's strings as a JSON object, for injecting into a page so client-side
    /// `t()` (in `@script`) can look them up. `{}` when the locale has no strings.
    public func jsonTable(for locale: String) -> String {
        let locale = normalizeLocale(locale)
        var pairs: [(name: String, value: JSONValue)] = []
        for table in tables where utf8Equal(table.locale, locale) {
            for entry in table.entries { pairs.append((name: entry.key, value: .string(entry.value))) }
        }
        // Escape `<` so a value containing "</script>" can't break out of the
        // injecting <script> tag (byte-wise, to stay embedded-clean).
        var safe: [UInt8] = []
        for byte in JSONValue.object(pairs).serialize() {
            if byte == 0x3C { safe.append(contentsOf: Array("\\u003c".utf8)) } else { safe.append(byte) }
        }
        return String(decoding: safe, as: UTF8.self)
    }

    /// The translation for `key` in `locale`, falling back to the default locale then
    /// the key itself, with `{name}` placeholders replaced from `params`.
    public func t(_ key: String, locale: String, _ params: [String: String] = [:]) -> String {
        let value = lookup(key, in: normalizeLocale(locale)) ?? lookup(key, in: defaultLocale) ?? key
        return params.isEmpty ? value : interpolate(value, params)
    }

    private func lookup(_ key: String, in locale: String) -> String? {
        for table in tables where utf8Equal(table.locale, locale) {
            for entry in table.entries where utf8Equal(entry.key, key) { return entry.value }
        }
        return nil
    }

    /// Replace `{name}` placeholders with `params["name"]`, byte-wise. An unmatched
    /// placeholder is left as-is so a missing value is visible, not silently blank.
    /// The param is matched by iterating, not by Dictionary subscript — String
    /// hashing/comparison pulls Unicode-normalization tables that don't link in
    /// the embedded guest.
    private func interpolate(_ template: String, _ params: [String: String]) -> String {
        let bytes = Array(template.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x7B, let close = indexOfClose(bytes, from: i + 1) {   // '{'
                let name = String(decoding: bytes[(i + 1)..<close], as: UTF8.self)
                var value: String? = nil
                for entry in params where utf8Equal(entry.key, name) {
                    value = entry.value
                    break
                }
                if let value {
                    out.append(contentsOf: Array(value.utf8))
                    i = close + 1
                    continue
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func indexOfClose(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == 0x7D { return i }        // '}'
            if bytes[i] == 0x7B { return nil }      // nested '{' — not a placeholder
            i += 1
        }
        return nil
    }
}

import PlumeRuntime

/// Resolve the request's language and make `t(...)` work for the rest of the request.
/// Order of preference: a `?lang=` query override, a `locale` cookie, then the
/// `Accept-Language` header, falling back to the translations' default. Install it in
/// `buildApp()` (`app.use(localization(plumeKitTranslations))`); after that, handlers
/// and views call `t("key")` with no locale or `Translations` to pass around.
public func localization(_ translations: Translations,
                         queryOverride: String = "lang",
                         cookieOverride: String = "locale") -> MiddlewareFunction {
    let available = translations.locales
    return { request, next in
        let locale: String
        let q = request.queryParams[queryOverride].map(normalizeLocale)
        let c = extractCookie(request, name: cookieOverride).map(normalizeLocale)
        if let q, available.contains(where: { utf8Equal($0, q) }) {
            locale = q
        } else if let c, available.contains(where: { utf8Equal($0, c) }) {
            locale = c
        } else {
            // No match negotiates to the configured default, not an arbitrary first.
            locale = request.preferredLanguage(available: available, default: translations.defaultLocale)
        }
        let state = LocalizationState(locale: locale, render: { key, loc, params in
            translations.t(key, locale: loc, params)
        }, table: { loc in translations.jsonTable(for: loc) })
        #if hasFeature(Embedded)
        RenderContext.localization = state
        let response = try await next(request)
        RenderContext.localization = nil
        return response
        #else
        return try await RenderContext.$localization.withValue(state) { try await next(request) }
        #endif
    }
}

extension Request {
    /// The best match between the request's `Accept-Language` and the locales your app
    /// ships, or `fallback` when nothing matches. Prefix-matches language tags (`pt-BR`
    /// matches available `pt`), in the header's given order.
    public func preferredLanguage(available: [String], default fallback: String) -> String {
        guard let header = headers.first("accept-language"), !available.isEmpty else {
            return fallback
        }
        let matched = negotiateLanguage(header: header, available: available)
        return matched ?? fallback
    }

    /// Convenience overload falling back to the first available language.
    public func preferredLanguage(available: [String]) -> String {
        preferredLanguage(available: available, default: available.first ?? "en")
    }

    private func negotiateLanguage(header: String, available: [String]) -> String? {
        // "pt-BR,pt;q=0.9,en;q=0.8" → tags in order; q-weights are already ordered
        // by every real browser, so honor given order. Parsed byte-wise (no
        // Unicode-aware String splitting — the same discipline as form decoding).
        var tag: [UInt8] = []
        var tags: [String] = []
        func flush() {
            if !tag.isEmpty { tags.append(String(decoding: tag, as: UTF8.self)) }
            tag = []
        }
        var skippingParameters = false
        for byte in Array(header.utf8) {
            switch byte {
            case 0x2C:   // ',' — next tag
                flush(); skippingParameters = false
            case 0x3B:   // ';' — q-weight parameters follow
                skippingParameters = true
            case 0x20, 0x09:   // spaces around tags
                continue
            default:
                // Language tags compare case-insensitively (BCP 47): fold to lowercase.
                if !skippingParameters {
                    tag.append(byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte)
                }
            }
        }
        flush()
        for candidate in tags {
            for locale in available {
                if utf8Equal(candidate, locale) || asciiHasPrefix(candidate, locale + "-") {
                    return locale
                }
            }
        }
        return nil
    }
}
