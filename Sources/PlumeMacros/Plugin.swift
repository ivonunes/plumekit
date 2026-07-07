import SwiftCompilerPlugin
import SwiftSyntaxMacros

// The compiler plugin entry point. Runs on the HOST during compilation; nothing
// here is linked into the app or the wasm guest — only the code it emits is.
@main
struct PlumeKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [ModelMacro.self, ColumnMacro.self]
}
