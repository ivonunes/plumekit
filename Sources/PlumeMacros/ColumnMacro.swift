import SwiftSyntax
import SwiftSyntaxMacros

// `@Column("db_name")` — a pure MARKER peer macro. It emits no peers; it exists so
// the `@Model` member macro can read an explicit SQL column name off a stored
// property whose Swift name differs from the database column (the database-first
// adoption case: `var displayName` ⇄ column `display_name`). The override is
// parsed from the attribute syntax by `ModelMacro`, not produced here.
public struct ColumnMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
