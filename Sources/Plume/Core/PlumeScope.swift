import Foundation

/// The single definition of how a scoped `@style` block's identifier is derived,
/// shared by the interpreting renderer, the compiling back-end, and the build-time
/// asset bundle. Because all three compute the scope the same way from the same
/// declaration, the scoped CSS in the bundle and the scope attribute in the
/// emitted HTML always agree — no matter which back-end rendered the markup.
enum PlumeScope {
    /// Deterministic FNV-1a hash of a declaration's identity.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// The scope id for a scoped `@style`, e.g. `plume-a1b2c3d4e5f6a7b8`.
    static func styleScope(
        sourceName: String?, context: PlumeSourceContext?, css: String?, file: String?
    ) -> String {
        let key = [
            sourceName ?? "",
            context.map { "\($0.line):\($0.column)" } ?? "",
            css ?? "",
            file ?? "",
        ].joined(separator: "|")
        return "plume-\(stableHash(key))"
    }

    /// The scope id for a scoped `@script`.
    static func scriptScope(
        sourceName: String?, context: PlumeSourceContext?, js: String?, file: String?,
        language: PlumeScriptLanguage
    ) -> String {
        let key = [
            "script",
            sourceName ?? "",
            context.map { "\($0.line):\($0.column)" } ?? "",
            js ?? "",
            file ?? "",
            language.rawValue,
        ].joined(separator: "|")
        return "plume-\(stableHash(key))"
    }

    /// The attribute name carrying a scope id, e.g. `data-plume-scope-plume-…`.
    static func attribute(for scope: String) -> String {
        "data-plume-scope-\(scope)"
    }
}
