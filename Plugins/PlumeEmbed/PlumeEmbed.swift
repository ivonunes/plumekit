import PackagePlugin
import Foundation

// Build-tool plugin: embeds the framework's build-time assets into the `plumekit` CLI so
// a standalone (brew/tarball) install works without a framework checkout —
//   • docs/**/*.md              → DocsEmbedded.swift          (`plumekit mcp` search_docs)
//   • runtime/cloudflare/*      → CloudflareRuntimeEmbedded.swift (`plumekit build --target cloudflare`)
//
// The source trees (docs/, runtime/cloudflare/) are the single source of truth — the
// generated files land in the plugin work directory (compiled into PlumeKitCLI), never
// written to Sources/ and never committed. That removes the checked-in-file drift the old
// embed-*.py scripts + CI sync guards existed to police: the binary is always current.
//
// Applied only to PlumeKitCLI (nothing else depends on it), so it never runs in a user's
// app build — only when building the CLI itself, where both source trees are present.
@main
struct PlumeEmbed: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "plumekit-codegen")
        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL

        // docs/**/*.md (RECURSIVE — `subpathsOfDirectory` returns an array; a
        // DirectoryEnumerator can't be iterated in this async context).
        let docsDir = root.appending(path: "docs")
        var docsInputs: [URL] = []
        for sub in (try? FileManager.default.subpathsOfDirectory(atPath: docsDir.path)) ?? []
        where sub.hasSuffix(".md") {
            docsInputs.append(docsDir.appending(path: sub))
        }

        let runtimeDir = root.appending(path: "runtime/cloudflare")
        let runtimeInputs = ["worker.mjs", "wrangler.toml.template"].map { runtimeDir.appending(path: $0) }

        return [
            .buildCommand(
                displayName: "PlumeEmbed docs → \(target.name)",
                executable: tool.url,
                arguments: [docsDir.path, work.path, "docs-embed"],
                inputFiles: docsInputs,
                outputFiles: [work.appending(path: "DocsEmbedded.swift")]
            ),
            .buildCommand(
                displayName: "PlumeEmbed cloudflare-runtime → \(target.name)",
                executable: tool.url,
                arguments: [runtimeDir.path, work.path, "runtime-embed"],
                inputFiles: runtimeInputs,
                outputFiles: [work.appending(path: "CloudflareRuntimeEmbedded.swift")]
            ),
        ]
    }
}
