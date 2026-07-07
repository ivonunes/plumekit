import Foundation
import Plume

// The Plume templating commands, folded into the single `plumekit` binary (was the
// separate `plume` CLI). `plumekit compile|check|bundle|format|language-server`.
// Namespaced in an enum so its helpers don't clash with the framework commands.
enum PlumeTemplateCommands {
    /// Dispatch a templating subcommand; returns a process exit code.
    static func run(_ command: String, options: [String]) -> Int32 {
        do {
            switch command {
            case "check":
                try runCheck(options: options)
            case "compile":
                try runCompile(options: options)
            case "bundle":
                try runBundle(options: options)
            case "format":
                try runFormat(options: options)
            case "language-server":
                PlumeLanguageServer().run()
            case "version", "--version", "-v":
                print(PlumeVersion.current)
            default:
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static let helpLines = """
      compile [-o DIR] [path ...]  Compile Plume templates to Embedded-Swift render fns
      check [path ...]             Check Plume templates
      bundle -o DIR [path ...]     Build the content-hashed CSS/JS asset bundle
      format [--check] [path ...]  Format Plume templates
      language-server              Start the Plume language server
    """

    private static func runCompile(options: [String]) throws {
        var outputDirectory: String?
        var noSourceLocations = false
        var paths: [String] = []
        var index = options.startIndex
        while index < options.endIndex {
            let option = options[index]
            switch option {
            case "-o", "--out-dir":
                index = options.index(after: index)
                guard index < options.endIndex else {
                    throw PlumeError.template("\(option) requires a directory path.")
                }
                outputDirectory = options[index]
            case "--no-source-locations":
                noSourceLocations = true
            default:
                if option.hasPrefix("-") {
                    throw PlumeError.template("Unknown compile option \(option).")
                }
                paths.append(option)
            }
            index = options.index(after: index)
        }

        let files = try plumeFiles(paths: paths)
        guard !files.isEmpty else {
            print("No .plume templates found.")
            return
        }

        // The template roots, used to name generated files relative to them (so a
        // subfolder disambiguates: posts/Index.plume → posts.Index.plume.swift).
        let templateRoots = paths.isEmpty
            ? [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL]
            : paths.map { URL(fileURLWithPath: $0).standardizedFileURL }

        // Clear stale generated files so renamed/deleted templates don't linger.
        if let outputDirectory,
           let existing = try? FileManager.default.contentsOfDirectory(
               at: URL(fileURLWithPath: outputDirectory), includingPropertiesForKeys: nil) {
            for stale in existing where stale.lastPathComponent.hasSuffix(".plume.swift") {
                try? FileManager.default.removeItem(at: stale)
            }
        }

        // The compiling back-end desugars attribute helpers (class:, class+=,
        // attr?=, attr:value=) into inline @if blocks before parsing.
        let componentSources = Dictionary(uniqueKeysWithValues: try files.map { file in
            (relativePath(file), PlumeCompiledDesugar.desugar(try String(contentsOf: file, encoding: .utf8)))
        })

        var failed = false
        var compiledCount = 0
        let environment = try PlumeTemplateEnvironment(componentSources: componentSources)
        for file in files {
            let name = relativePath(file)
            let source = try componentSources[name] ?? String(contentsOf: file, encoding: .utf8)
            let options = PlumeSwiftOptions(emitSourceLocations: !noSourceLocations, sourcePath: name)

            let template = try PlumeTemplate(source, sourceName: name, environment: environment)
            let diagnostics = template.renderableDiagnostics()
            if !diagnostics.isEmpty {
                failed = true
                for diagnostic in diagnostics {
                    let location = diagnostic.context.map { "\(name):\($0.line):\($0.column): " } ?? ""
                    FileHandle.standardError.write(Data("\(location)\(diagnostic.message)\n".utf8))
                }
                continue
            }

            let swift = try template.compileToSwift(options: options)
            if let outputDirectory {
                let outputURL = URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent(swiftFileName(for: file, roots: templateRoots))
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try swift.write(to: outputURL, atomically: true, encoding: .utf8)
                compiledCount += 1
            } else {
                print(swift, terminator: "")
            }
        }
        if failed { exit(1) }
        // One summary line; per-file paths are noise when everything succeeds
        // (failures are reported individually above, with locations).
        if let outputDirectory, compiledCount > 0 {
            print("Compiled \(compiledCount) template\(compiledCount == 1 ? "" : "s") -> \(outputDirectory)")
        }

        // If we just compiled a project's Views into its App/Generated directory, finish
        // the pipeline here: build the content-hashed asset bundle into Public/ and bake
        // the `asset(...)` calls to their final URLs. This keeps `plumekit compile Views -o
        // Sources/App/Generated` self-contained — the generated code links on its own, so
        // recompiling by hand never leaves a dangling `asset()`.
        let generatedMarker = "Sources/App/Generated"
        if let outputDirectory,
           outputDirectory == generatedMarker || outputDirectory.hasSuffix("/" + generatedMarker) {
            let root = outputDirectory == generatedMarker
                ? "." : String(outputDirectory.dropLast(generatedMarker.count + 1))
            generateAppAssets(projectPath: root)
        }
    }

    private static func runBundle(options: [String]) throws {
        var outputDirectory: String?
        var paths: [String] = []
        var index = options.startIndex
        while index < options.endIndex {
            let option = options[index]
            switch option {
            case "-o", "--out-dir":
                index = options.index(after: index)
                guard index < options.endIndex else {
                    throw PlumeError.template("\(option) requires a directory path.")
                }
                outputDirectory = options[index]
            default:
                if option.hasPrefix("-") {
                    throw PlumeError.template("Unknown bundle option \(option).")
                }
                paths.append(option)
            }
            index = options.index(after: index)
        }
        guard let outputDirectory else {
            throw PlumeError.template("bundle requires an output directory, e.g. bundle -o dist/assets.")
        }
        let files = try plumeFiles(paths: paths)
        guard !files.isEmpty else { print("No .plume templates found."); return }

        let templates = Dictionary(uniqueKeysWithValues: try files.map { file in
            (relativePath(file), try String(contentsOf: file, encoding: .utf8))
        })
        let bundle = try PlumeAssetBundle.build(
            templates: templates,
            fileResolver: { path in try? String(contentsOfFile: path, encoding: .utf8) })
        try bundle.write(to: URL(fileURLWithPath: outputDirectory))
        for (logical, hashed) in bundle.manifest.sorted(by: { $0.key < $1.key }) {
            print("\(logical) -> \(hashed)")
        }
    }

    /// Build the content-hashed asset bundle (scoped `@style` + `@script` + the client
    /// runtime) into the project's `Public/` directory, and generate an `asset(_:)`
    /// resolver into the App module so compiled templates resolve the same hashed URLs as
    /// the interpreter. Called after `compile` on `new`/`serve`/`build`; a no-op with no
    /// `Views/`. Best-effort: a bundling error is logged, not fatal, so the app still runs.
    static func generateAppAssets(projectPath: String) {
        let viewsDir = projectPath + "/Views"
        guard FileManager.default.fileExists(atPath: viewsDir) else { return }
        do {
            let files = try plumeFiles(paths: [viewsDir])
            guard !files.isEmpty else { return }
            let templates = Dictionary(uniqueKeysWithValues: try files.map { file in
                (relativePath(file), try String(contentsOf: file, encoding: .utf8))
            })
            let bundle = try PlumeAssetBundle.build(
                templates: templates,
                fileResolver: { path in try? String(contentsOfFile: path, encoding: .utf8) })

            // Write the hashed files into Public/, clearing any stale bundle first so old
            // hashes don't accumulate. (Public/app.* is gitignored — it's regenerated.)
            let publicDir = projectPath + "/Public"
            try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
            // Only OUR content-hashed bundle files (app.<16 hex>.css/js) are swept;
            // a user's own Public/app.* files are never touched.
            let bundlePattern = try? NSRegularExpression(pattern: #"^app\.[0-9a-f]{16}\.(css|js)$"#)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: publicDir)) ?? [] {
                let range = NSRange(location: 0, length: (name as NSString).length)
                if bundlePattern?.firstMatch(in: name, range: range) != nil {
                    try? FileManager.default.removeItem(atPath: publicDir + "/" + name)
                }
            }
            try bundle.write(to: URL(fileURLWithPath: publicDir))

            // Resolve the compiled `asset("name")` calls to their final URLs, baked as
            // string literals right in the generated render functions. We do this as a
            // post-pass rather than a runtime `asset(_:)` function because a runtime String
            // lookup pulls in Unicode comparison, which does not link in the embedded-Wasm
            // guest. `app.*` resolve to their content-hashed name; anything else passes
            // through as `/name` (your own files in Public/).
            resolveCompiledAssetCalls(inGeneratedDirectory: projectPath + "/Sources/App/Generated",
                                      manifest: bundle.manifest)
        } catch {
            FileHandle.standardError.write(Data("plumekit: asset bundle skipped (\(error))\n".utf8))
        }
    }

    /// Rewrite `asset("name")` calls in the generated render functions to the resolved URL
    /// as a plain string literal — `asset("app.css")` → `"/app.<hash>.css"`. Keeps the
    /// generated code free of any runtime String lookup (Embedded-safe).
    private static func resolveCompiledAssetCalls(inGeneratedDirectory directory: String,
                                                  manifest: [String: String]) {
        // Anchored to the exact whole-line call shapes the generator emits
        // (`out.text(asset("…"))` / `out.require…(asset("…"))`), so template text that
        // merely CONTAINS "asset(" can never be rewritten across literal boundaries.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory),
              let regex = try? NSRegularExpression(
                  pattern: #"^(\s*out\.(?:text|requireStylesheet|requireScript)\()asset\("([^"\\]*)"\)(\)\s*)$"#,
                  options: [.anchorsMatchLines]) else { return }
        for entry in entries where entry.hasSuffix(".swift") {
            let path = directory + "/" + entry
            guard let source = try? String(contentsOfFile: path, encoding: .utf8),
                  source.contains("asset(") else { continue }
            let ns = source as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                let prefix = ns.substring(with: match.range(at: 1))
                let logical = ns.substring(with: match.range(at: 2))
                let suffix = ns.substring(with: match.range(at: 3))
                let url = manifest[logical].map { "/" + $0 } ?? "/" + logical
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result += prefix + "\"\(url)\"" + suffix
                cursor = match.range.location + match.range.length
            }
            result += ns.substring(from: cursor)
            if result != source { try? result.write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }

    private static func runCheck(options: [String]) throws {
        let files = try plumeFiles(paths: options.filter { !$0.hasPrefix("-") })
        guard !files.isEmpty else { print("No .plume templates found."); return }

        // The compiling back-end desugars attribute helpers (class:, class+=,
        // attr?=, attr:value=) into inline @if blocks before parsing.
        let componentSources = Dictionary(uniqueKeysWithValues: try files.map { file in
            (relativePath(file), PlumeCompiledDesugar.desugar(try String(contentsOf: file, encoding: .utf8)))
        })
        let environment = PlumeLanguageSupport.environment(componentSources: componentSources)
        var failed = false
        for file in files {
            let name = relativePath(file)
            let source = try componentSources[name] ?? String(contentsOf: file, encoding: .utf8)
            let diagnostics = PlumeLanguageSupport.diagnostics(for: source, sourceName: name, environment: environment)
            for diagnostic in diagnostics {
                failed = true
                print("\(diagnostic.sourceName ?? name):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)")
            }
        }
        if failed { exit(1) }
        print("Plume check passed (\(files.count) templates).")
    }

    private static func runFormat(options: [String]) throws {
        if options.contains("--stdin") {
            print(PlumeFormatter.format(readStandardInput()), terminator: "")
            return
        }
        let checkOnly = options.contains("--check")
        let files = try plumeFiles(paths: options.filter { !$0.hasPrefix("-") })
        guard !files.isEmpty else { print("No .plume templates found."); return }

        var changed: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let formatted = PlumeFormatter.format(source)
            guard formatted != source else { continue }
            changed.append(relativePath(file))
            if !checkOnly { try formatted.write(to: file, atomically: true, encoding: .utf8) }
        }
        if changed.isEmpty { print("Plume templates are already formatted."); return }
        for path in changed { print("\(checkOnly ? "Would format" : "Formatted") \(path)") }
        if checkOnly { exit(1) }
    }

    /// The generated Swift file name for a template. Encodes the path relative to its
    /// template root (`posts/Index.plume` → `posts.Index.plume.swift`) so subfolders
    /// disambiguate, and the `.plume.swift` suffix ensures it's globally unique and can
    /// never collide with a hand-written `.swift` (a model, controller, …).
    private static func swiftFileName(for file: URL, roots: [URL]) -> String {
        let fileComponents = file.standardizedFileURL.deletingPathExtension().pathComponents
        var stem = file.deletingPathExtension().lastPathComponent
        for root in roots {
            let rootComponents = root.standardizedFileURL.pathComponents
            if fileComponents.count > rootComponents.count,
               Array(fileComponents.prefix(rootComponents.count)) == rootComponents {
                stem = fileComponents.dropFirst(rootComponents.count).joined(separator: ".")
                break
            }
        }
        return stem + ".plume.swift"
    }

    private static func plumeFiles(paths: [String]) throws -> [URL] {
        let roots = paths.isEmpty
            ? [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
            : paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var files: [URL] = []
        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isRegularFile == true, root.pathExtension == "plume" {
                files.append(root); continue
            }
            guard values?.isDirectory == true,
                  let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                if shouldSkipDirectory(file) { enumerator.skipDescendants(); continue }
                if file.pathExtension == "plume",
                   (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(file)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func shouldSkipDirectory(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return [".build", ".cache", ".git", "dist", "node_modules"].contains(url.lastPathComponent)
    }

    private static func relativePath(_ url: URL) -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return path }
        return path.dropFirst(root.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func readStandardInput() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
