import Foundation

public enum PlumeClientScriptCompiler {
    public static func compile(_ source: String, sourceName: String? = nil) throws -> String {
        var compiler = ClientScriptCompiler(source: source, sourceName: sourceName)
        return try compiler.compile()
    }

    public static func compileBrowserRuntime(_ source: String, sourceName: String? = nil) throws -> String {
        let compiler = ClientScriptCompiler(source: source, sourceName: sourceName)
        return compiler.compileBrowserRuntime()
    }
}
