import PackagePlugin
import Foundation

// Build-tool plugin: regenerates PlumeCore's manifest-driven code on every build.
//
// Per target, it emits exactly one file into the plugin work directory (compiled
// into that target automatically — never written to Sources/, never committed):
//   • target depends on PlumeServer → Composition.swift (native adapter wiring)
//   • otherwise (the App module)      → Bindings.swift     (typed capability gate)
//
// The actual TOML→Swift work is the `plumekit-codegen` tool; this just wires inputs
// (Drivers.toml) and outputs so SwiftPM rebuilds incrementally.
@main
struct PlumeKitCodegen: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "plumekit-codegen")
        let manifest = context.package.directoryURL.appending(path: "plumekit.toml")

        // The native composition imports PlumeServer and the AWS composition imports
        // PlumeAWS, so each belongs only in the target that depends on it; everything
        // else (the App module) gets the typed Bindings gate.
        func dependsOn(_ productName: String) -> Bool {
            target.dependencies.contains { dependency in
                if case .product(let product) = dependency { return product.name == productName }
                return false
            }
        }
        let kind: String
        if dependsOn("PlumeServer") { kind = "composition" }
        else if dependsOn("PlumeAWS") { kind = "aws-composition" }
        else { kind = "bindings" }

        var inputs = [manifest]
        var outputs = [context.pluginWorkDirectoryURL.appending(path:
            kind == "bindings" ? "Bindings.swift" : "Composition.swift")]

        // The bindings step (App module) also discovers migrations/seeders, so their
        // files are inputs (adding one must retrigger codegen) and PlumeKitData.swift
        // is a second output.
        if kind == "bindings" {
            outputs.append(context.pluginWorkDirectoryURL.appending(path: "PlumeKitData.swift"))
            let root = context.package.directoryURL
            let databaseDir = root.appending(path: "Sources/App/Database")
            for sub in ["Migrations", "Seeders"] {
                let dir = databaseDir.appending(path: sub)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)) ?? []
                inputs.append(contentsOf: files.filter { $0.pathExtension == "swift" })
            }
            // Translations/<locale>.json are compiled into PlumeKitData too.
            let translationsDir = root.appending(path: "Translations")
            let jsonFiles = (try? FileManager.default.contentsOfDirectory(
                at: translationsDir, includingPropertiesForKeys: nil)) ?? []
            inputs.append(contentsOf: jsonFiles.filter { $0.pathExtension == "json" })

            // Jobs/** (RECURSIVE — organize into subfolders) + the single Schedules.swift
            // feed the generated buildJobs()/buildSchedule(); changing them retriggers codegen.
            // `subpathsOfDirectory` (an array) — a DirectoryEnumerator can't be iterated in
            // this async context.
            let jobsDir = root.appending(path: "Sources/App/Jobs")
            let jobSubpaths = (try? FileManager.default.subpathsOfDirectory(atPath: jobsDir.path)) ?? []
            for sub in jobSubpaths where sub.hasSuffix(".swift") {
                inputs.append(jobsDir.appending(path: sub))
            }
            let schedules = root.appending(path: "Sources/App/Schedules.swift")
            if FileManager.default.fileExists(atPath: schedules.path) { inputs.append(schedules) }
        }

        return [
            .buildCommand(
                displayName: "PlumeKitCodegen \(kind) → \(target.name)",
                executable: tool.url,
                arguments: [manifest.path, context.pluginWorkDirectoryURL.path, kind],
                inputFiles: inputs,
                outputFiles: outputs
            )
        ]
    }
}
