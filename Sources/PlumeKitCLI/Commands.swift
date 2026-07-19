import Foundation
import Plume

// MARK: - Small helpers

func errorLine(_ message: String) {
    FileHandle.standardError.write(Data("\(Style.red("plumekit:")) \(message)\n".utf8))
}

func writeFile(_ contents: String, to path: String) -> Bool {
    do { try contents.write(toFile: path, atomically: true, encoding: .utf8); return true }
    catch { errorLine("failed to write \(path): \(error)"); return false }
}

private func copyFile(_ from: String, to: String) {
    try? FileManager.default.removeItem(atPath: to)
    try? FileManager.default.copyItem(atPath: from, toPath: to)
}

private func absolutePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

/// A wrangler-safe project name derived from the directory name.
private func projectName(_ path: String) -> String {
    let name = URL(fileURLWithPath: absolutePath(path)).lastPathComponent.lowercased()
    let cleaned = String(name.map { ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
    return cleaned.isEmpty ? "plumekit-app" : cleaned
}

/// Locate the PlumeKit framework checkout (the package that owns this CLI), used to
/// point a generated project's path dependency at the local framework.
private func deriveFrameworkRoot() -> String? {
    let exePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    var dir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
    for _ in 0..<6 {
        let runtime = dir.appendingPathComponent("runtime/cloudflare/worker.mjs").path
        let manifest = dir.appendingPathComponent("Package.swift").path
        if FileManager.default.fileExists(atPath: runtime),
           FileManager.default.fileExists(atPath: manifest) {
            return dir.path
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// The framework checkout root, preferring PLUMEKIT_PATH, else derived from the
/// CLI executable's location. Used to locate runtime/cloudflare.
func frameworkRoot() -> String? {
    if let path = ProcessInfo.processInfo.environment["PLUMEKIT_PATH"] {
        let abs = absolutePath(path)
        if FileManager.default.fileExists(atPath: abs + "/runtime/cloudflare/worker.mjs") { return abs }
    }
    return deriveFrameworkRoot()
}

/// The single `dependencies:` entry a generated project should use for the merged
/// PlumeKit package (framework + Plume templating). `name:` pins the identity to
/// PlumeKit (the repo dir is `plume`).
private func resolvePlumeKitDependency(explicitPath: String?) -> String {
    if let path = explicitPath ?? ProcessInfo.processInfo.environment["PLUMEKIT_PATH"] {
        return ".package(name: \"PlumeKit\", path: \"\(absolutePath(path))\")"
    }
    if let root = deriveFrameworkRoot() {
        return ".package(name: \"PlumeKit\", path: \"\(root)\")"
    }
    // Standalone install: depend on the released package, pinned to this CLI's own version
    // (so the floor can never drift from PlumeVersion).
    return ".package(url: \"https://github.com/ivonunes/plumekit.git\", from: \"\(PlumeVersion.current)\")"
}

// MARK: - Plume templates

/// Compile `<project>/Views/*.plume` → `<project>/Sources/App/Generated/*.swift`
/// before building, so the generated render functions are always fresh. No-op if
/// there are no templates.
///
/// The Plume compiler is **embedded** in this CLI (a library dependency), so no
/// separate `plume` install is needed — templates are compiled in-process.
@discardableResult
func compileTemplates(projectPath: String) -> Int32 {
    // Views live in Views/ (older projects used Templates/ — still honored).
    let viewsDir = projectPath + "/Views"
    let templatesDir = FileManager.default.fileExists(atPath: viewsDir)
        ? viewsDir : projectPath + "/Templates"
    guard FileManager.default.fileExists(atPath: templatesDir) else { return 0 }
    // One compile implementation: delegate to the same path as `plumekit compile`,
    // which recurses into subfolders and gives generated files unique, collision-proof
    // names (`posts/Index.plume` → `posts.Index.plume.swift`).
    // `plumekit compile` builds the asset bundle into Public/ and bakes the asset() calls
    // itself when it writes into Sources/App/Generated (see runCompile), so this one call
    // is the whole view pipeline.
    return PlumeTemplateCommands.run(
        "compile", options: [templatesDir, "-o", projectPath + "/Sources/App/Generated"])
}

// MARK: - new

func newCommand(name: String, plumekitPath: String?) -> Int32 {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: name) else {
        errorLine("'\(name)' already exists")
        return 1
    }

    let options = scaffoldOptions()
    let dependency = resolvePlumeKitDependency(explicitPath: plumekitPath)
    for file in Templates.projectFiles(name: name, plumeKitDependency: dependency, options: options) {
        let fullPath = name + "/" + file.path
        let directory = (fullPath as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !writeFile(file.contents, to: fullPath) { return 1 }
        if file.path == "plumekit" {   // the CLI wrapper must be executable
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fullPath)
        }
    }

    // CI workflows, if chosen.
    if let provider = options.ciProvider,
       let ciFiles = CITemplates.files(provider: provider, target: options.defaultTarget,
                                       capabilities: options.capabilities) {
        for (filePath, contents) in ciFiles {
            let fullPath = name + "/" + filePath
            try? fileManager.createDirectory(atPath: (fullPath as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
            _ = writeFile(contents, to: fullPath)
        }
    }

    // Compile the Plume templates now so the new project builds immediately. The
    // composition root + typed Bindings are produced by the PlumeKitCodegen build
    // plugin on every `swift build` (so no codegen is committed).
    _ = compileTemplates(projectPath: name)

    print("✓ Created \(name)/ — a PlumeKit app (with a Plume view)")
    print("  Routes: \(name)/Sources/App/Routes.swift  ·  Views: \(name)/Views/")
    print("")
    print("Next:")
    print("  cd \(name)")
    print("  ./plumekit dev       # serve on http://127.0.0.1:8080, restart on change")
    print("  ./plumekit build     # build the default target (\(options.defaultTarget))")
    print("  ./plumekit deploy    # migrate + build + deploy")
    return 0
}

/// Gather scaffold options — interactively at a TTY, otherwise sensible defaults.
private func scaffoldOptions() -> ScaffoldOptions {
    guard Prompt.isInteractive else { return ScaffoldOptions() }
    var options = ScaffoldOptions()

    // secrets is preselected alongside kv: the scaffold always installs CSRF
    // protection, which reads CSRF_SECRET through the secrets binding — without it
    // every form POST answers 500. (Env-backed natively, so it costs nothing.)
    let capNames = ["kv", "database", "storage", "cache", "queue", "http", "secrets"]
    let picked = Prompt.multiselect("Capabilities?", capNames, preselected: [0, 6])
    options.capabilities = picked.isEmpty ? ["kv", "secrets"] : Set(picked.map { capNames[$0] })
    if !options.capabilities.contains("secrets") {
        print(Style.dim("  Note: without `secrets`, CSRF form protection can't sign tokens —"))
        print(Style.dim("  form POSTs will fail until you enable it in plumekit.toml."))
    }

    let targets = ["cloudflare", "aws", "native"]
    let targetLabels = ["cloudflare (Workers)", "aws (Lambda)", "native (standalone server)"]
    options.defaultTarget = targets[Prompt.select("Default build/deploy target?", targetLabels)]
    let target = options.defaultTarget

    if options.capabilities.contains("database") {
        if target == "cloudflare" {
            // Cloudflare's database is D1 (SQLite). Match it locally so dev and
            // production run the same engine — no question to ask.
            options.nativeDatabaseDriver = "sqlite"
            print(Style.dim("  Using SQLite locally to match Cloudflare D1."))
        } else {
            let drivers = ["sqlite", "postgres"]
            options.nativeDatabaseDriver = drivers[Prompt.select("Native database driver?", drivers)]
        }
    }

    // A Dockerfile only matters when you deploy the native server as a container.
    // Cloudflare (Wasm) and AWS (Lambda zip) don't use one.
    options.includeDockerfile = target == "native"
        ? Prompt.confirm("Add a Dockerfile (deploy the standalone server as a container)?")
        : false

    let ci = ["none", "github", "gitlab", "forgejo"]
    let choice = ci[Prompt.select("Add CI workflows (test on PR, deploy on push to main)?", ci)]
    options.ciProvider = choice == "none" ? nil : choice
    print("")
    return options
}

// MARK: - serve

func serveCommand(path: String, host: String, port: UInt16) -> Int32 {
    // Development mode: the spawned server inherits this and shows the dev error page
    // when a handler throws. A user-set PLUMEKIT_ENV always wins (overwrite = 0).
    setenv("PLUMEKIT_ENV", "development", 0)
    print("→ plumekit serve — building & starting the native server on http://\(host):\(port)")
    return runAppServer(path: path, ["--host", host, "--port", String(port)])
}

// MARK: - build

/// Where a Cloudflare bundle lands: `dist/cloudflare` for the base deployment,
/// `dist/cloudflare-<env>` per environment — parallel bundles must not clobber
/// each other's generated wrangler.toml (that is what `wrangler dev`/`tail` read).
func cloudflareBundleDir(path: String, outDir: String, env: String?) -> String {
    path + "/" + outDir + "/cloudflare" + (env.map { "-\($0)" } ?? "")
}

func buildCloudflareCommand(path: String, outDir: String = "dist", env: String? = nil,
                            showNextSteps: Bool = true) -> Int32 {
    if let env, !validateDeclaredEnvironment(projectPath: path, target: "cloudflare", env: env) {
        return 1
    }
    guard let sdk = embeddedWasmSDK() ?? installEmbeddedWasmSDK() else {
        errorLine("no Embedded-Swift WebAssembly SDK is installed, and none is published for this toolchain.")
        errorLine("Install one (see swift.org's 'Getting Started with Swift SDKs for WebAssembly'):")
        errorLine("  swift sdk install <…_wasm.artifactbundle URL> --checksum <…>")
        return 1
    }

    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }

    print("→ Building Worker → WebAssembly with \(sdk)")
    // Native `String` ops (==, hasPrefix, lowercased, split, Dictionary<String,_>) link in
    // the guest because PlumeWorker links Swift's Unicode data tables (see Package.swift) —
    // no build-side plumbing needed here.
    let buildStatus = runInherit("swift", [
        "build", "--package-path", path, "--swift-sdk", sdk, "-c", "release",
        "--product", "Worker",
        "-Xswiftc", "-Xclang-linker", "-Xswiftc", "-mexec-model=reactor",
        // Optimize for size, not speed: Cloudflare's module-size limit is a hard deploy
        // wall, while a Worker request is I/O-bound (DB/KV/network + byte-wise HTML
        // rendering), so the runtime cost is negligible and a smaller module also
        // cold-starts faster. ~7% smaller (compressed) on top of wasm-opt's -Oz.
        "-Xswiftc", "-Osize",
    ])
    guard buildStatus == 0 else {
        errorLine("wasm build failed")
        return buildStatus
    }

    let wasmIn = path + "/.build/wasm32-unknown-wasip1/release/Worker.wasm"
    guard FileManager.default.fileExists(atPath: wasmIn) else {
        errorLine("expected wasm not found at \(wasmIn)")
        return 1
    }
    let rawSize = fileSize(wasmIn)

    let bundleDir = cloudflareBundleDir(path: path, outDir: outDir, env: env)
    try? FileManager.default.createDirectory(atPath: bundleDir, withIntermediateDirectories: true)
    let wasmOut = bundleDir + "/app.wasm"

    if let wasmOpt = provisionedWasmOpt() {
        // -Oz for size, and strip DWARF/producers/target-features custom sections:
        // SwiftPM's release config compiles with `-g`, and binaryen ≥ v116 *preserves*
        // (and rewrites) DWARF through -O passes, so without --strip-debug the shipped
        // wasm carries ~16 MB of debug sections — 5× the actual code — which blows
        // Cloudflare's compressed module-size limit for no runtime benefit.
        // Override for special builds (e.g. keep DWARF for profiling) with
        // PLUMEKIT_WASM_OPT_ARGS, a space-separated wasm-opt argument list.
        let defaultArgs = ["-Oz", "--strip-debug", "--strip-producers", "--strip-target-features"]
        let optArgs = ProcessInfo.processInfo.environment["PLUMEKIT_WASM_OPT_ARGS"]
            .map { $0.split(separator: " ").map(String.init) } ?? defaultArgs
        print("→ Optimizing: wasm-opt \(optArgs.joined(separator: " "))")
        if runInherit(wasmOpt, optArgs + [wasmIn, "-o", wasmOut]) != 0 {
            errorLine("wasm-opt failed; emitting unoptimized wasm")
            copyFile(wasmIn, to: wasmOut)
        }
    } else {
        errorLine("wasm-opt unavailable (download failed?); emitting unoptimized wasm")
        copyFile(wasmIn, to: wasmOut)
    }
    let optSize = fileSize(wasmOut)

    // The JS glue + wrangler config ship EMBEDDED in this binary (generated at build time
    // from runtime/cloudflare by the PlumeEmbed plugin), so a standalone
    // install builds Cloudflare bundles with no framework checkout. When a checkout
    // IS present (framework development), its files win so edits take effect
    // without regenerating.
    let name = projectName(path)
    var workerJS = CloudflareRuntimeEmbedded.workerJS
    if let root = frameworkRoot() {
        let runtimeDir = root + "/runtime/cloudflare"
        if let checkoutWorker = try? String(contentsOfFile: runtimeDir + "/worker.mjs", encoding: .utf8) {
            workerJS = checkoutWorker
        }
    }
    // One-time: fold a legacy user-owned root wrangler.toml into plumekit.toml.
    absorbLegacyWranglerToml(projectPath: path, projectName: name)

    // wrangler.toml is a GENERATED artifact: emitted into the bundle from
    // plumekit.toml's [targets.cloudflare] (plus wrangler.extra.toml, verbatim),
    // which keeps `wrangler dev`/`tail` and a manual `wrangler deploy` working.
    let settings = CloudflareSettings.read(projectPath: path, projectName: name, env: env)
    let wrangler = generateWranglerToml(
        settings: settings,
        extra: try? String(contentsOfFile: path + "/wrangler.extra.toml", encoding: .utf8))
    guard writeFile(workerJS, to: bundleDir + "/worker.mjs"),
          writeFile(wrangler, to: bundleDir + "/wrangler.toml") else {
        return 1
    }

    // Copy the app's static files so Cloudflare's [assets] can serve them (the runtime
    // bundle, styles, images) at the same URL paths the native server serves from Public/.
    let publicSrc = path + "/Public"
    var copiedAssets = 0
    if FileManager.default.fileExists(atPath: publicSrc) {
        let publicDst = bundleDir + "/public"
        try? FileManager.default.removeItem(atPath: publicDst)
        try? FileManager.default.copyItem(atPath: publicSrc, toPath: publicDst)
        // Content-hashed bundle files cache forever (Workers Assets honours a
        // `_headers` file). The app's own _headers, if present, wins untouched.
        if !FileManager.default.fileExists(atPath: publicDst + "/_headers") {
            _ = writeFile("""
            /app.*
              Cache-Control: public, max-age=31536000, immutable

            """, to: publicDst + "/_headers")
        }
        copiedAssets = ((try? FileManager.default.contentsOfDirectory(atPath: publicDst)) ?? []).count
    }

    let savedPct = rawSize > 0 ? Int((Double(rawSize - optSize) / Double(rawSize)) * 100) : 0
    print("")
    print("✓ Cloudflare Worker bundle → \(bundleDir)")
    print("  worker.mjs    module-worker entry (JSPI host bindings, dependency-free)")
    print("  app.wasm      \(rawSize) → \(optSize) bytes  (wasm-opt, −\(savedPct)%)")
    print("  wrangler.toml name = \"\(settings.name)\"")
    if copiedAssets > 0 {
        print("  public/       \(copiedAssets) static files (served by Cloudflare [assets])")
    }
    // Suppressed under `deploy`, which is already doing the deploy — printing "now run
    // wrangler deploy" mid-deploy is confusing.
    if showNextSteps {
        print("")
        print("Next:")
        print("  cd \(bundleDir)")
        print("  # create a KV namespace and set its id in wrangler.toml, then:")
        print("  wrangler dev      # serve the Wasm worker locally")
        print("  wrangler deploy   # deploy (requires a Cloudflare account / login)")
    }
    return 0
}

func buildAWSCommand(path: String, outDir: String = "dist", showNextSteps: Bool = true) -> Int32 {
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }

    // Lambda runs a Linux binary under the `provided.al2` runtime, whose entrypoint
    // is a file named `bootstrap`. Cross-build with a static Linux Swift SDK when one
    // is installed; otherwise build with the host toolchain (fine for LocalStack via a
    // Linux container / local invoke, but a real Lambda deploy needs the Linux build).
    let linuxSDK = staticLinuxSDK()
    var buildArgs = ["build", "--package-path", path, "-c", "release", "--product", "Lambda"]
    if let linuxSDK { buildArgs += ["--swift-sdk", linuxSDK] }
    print(Style.cyan("→") + " Building Lambda \(linuxSDK.map { "for \($0)" } ?? "(host toolchain)")")
    let status = runInherit("swift", buildArgs)
    guard status == 0 else {
        errorLine("Lambda build failed.")
        errorLine("Does this project have a `Lambda` executable target? The AWS guide (docs/aws.md)")
        errorLine("covers the Lambda front-end and the [targets.aws] plumekit.toml profile.")
        return status
    }

    var showBinArgs = buildArgs
    showBinArgs.append("--show-bin-path")
    let (binStatus, binOut) = captureStdout("swift", showBinArgs)
    let binDir = binOut.trimmingCharacters(in: .whitespacesAndNewlines)
    guard binStatus == 0, FileManager.default.fileExists(atPath: binDir + "/Lambda") else {
        errorLine("couldn't locate the built Lambda binary")
        return 1
    }

    let bundleDir = path + "/" + outDir + "/aws"
    try? FileManager.default.createDirectory(atPath: bundleDir, withIntermediateDirectories: true)
    let bootstrap = bundleDir + "/bootstrap"
    copyFile(binDir + "/Lambda", to: bootstrap)
    runInherit("chmod", ["+x", bootstrap])

    let haveZip = toolExists("zip")
    if haveZip {
        // -j keeps `bootstrap` at the archive root, as provided.al2 requires.
        runInherit("zip", ["-j", "-q", bundleDir + "/function.zip", bootstrap])
    }
    _ = writeFile(Templates.awsDeployReadme(name: projectName(path)), to: bundleDir + "/README.md")

    // Copy the app's static files so they're ready to upload to S3 + front with CloudFront
    // (routing dynamic paths to the Lambda). See the bundle README for the setup.
    let awsPublicSrc = path + "/Public"
    var awsAssets = 0
    if FileManager.default.fileExists(atPath: awsPublicSrc) {
        let dst = bundleDir + "/public"
        try? FileManager.default.removeItem(atPath: dst)
        try? FileManager.default.copyItem(atPath: awsPublicSrc, toPath: dst)
        awsAssets = ((try? FileManager.default.contentsOfDirectory(atPath: dst)) ?? []).count
    }

    print("")
    print(Style.green("✓") + " " + Style.bold("AWS Lambda bundle") + " → \(bundleDir)")
    print("  bootstrap     provided.al2 entrypoint (\(fileSize(bootstrap)) bytes)")
    if haveZip { print("  function.zip  deployable archive") }
    if awsAssets > 0 { print("  public/       \(awsAssets) static files → S3 + CloudFront (see README)") }
    print("  README.md     env vars + deploy / LocalStack steps")
    if linuxSDK == nil {
        print("")
        print(Style.yellow("⚠️  Built with the host toolchain. A real Lambda deploy needs a Linux binary:"))
        print("   install a static Linux Swift SDK (swift.org) or set PLUMEKIT_LINUX_SDK, then rebuild.")
    }
    if showNextSteps {
        print("")
        print("Next: test locally with LocalStack (see \(bundleDir)/README.md).")
    }
    return 0
}

/// Build the standalone native server as a release binary. This is the artifact you
/// run yourself (systemd, a container, a VM) — `deploy --target native` wraps it in a
/// Docker image; this just produces the optimized binary and prints its path.
func buildNativeCommand(path: String) -> Int32 {
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }

    let buildArgs = ["build", "--package-path", path, "-c", "release", "--product", "Server"]
    print(Style.cyan("→") + " Building the standalone server (release)")
    let status = runInherit("swift", buildArgs)
    guard status == 0 else {
        errorLine("native server build failed. Does this project have a `Server` executable target?")
        return status
    }

    let (binStatus, binOut) = captureStdout("swift", buildArgs + ["--show-bin-path"])
    let binDir = binOut.trimmingCharacters(in: .whitespacesAndNewlines)
    let binary = binDir + "/Server"
    guard binStatus == 0, FileManager.default.fileExists(atPath: binary) else {
        errorLine("couldn't locate the built Server binary")
        return 1
    }

    print("")
    print(Style.green("✓") + " " + Style.bold("Standalone server → \(binary)"))
    print("  \(fileSize(binary)) bytes, optimized")
    print("")
    print(Style.bold("Next:"))
    print("  \(binary) --host 0.0.0.0 --port 8080   " + Style.dim("# run it"))
    print("  " + Style.dim("or: plumekit deploy --target native   # wrap it in a Docker image"))
    return 0
}

// MARK: - deploy

/// Deploy one target: run data steps (migrate/seed), build, and ship it.
func deployCommand(target: String, path: String, outDir: String, migrate: Bool, seed: Bool,
                   env: String? = nil) -> Int32 {
    switch target {
    case "cloudflare": return deployCloudflare(path: path, outDir: outDir, migrate: migrate, seed: seed, env: env)
    case "aws":        return deployAWS(path: path, outDir: outDir, migrate: migrate, seed: seed, env: env)
    case "native":     return deployNative(path: path, migrate: migrate, seed: seed, env: env)
    default:
        errorLine("unknown deploy target '\(target)'. Supported: cloudflare, aws, native")
        return 1
    }
}

/// Pre-deploy data steps. Cloudflare targets the remote D1; native/AWS use the app's
/// runMigrations/runSeed against the configured database.
private func deployDataSteps(path: String, d1: D1Target?, migrate: Bool, seed: Bool,
                             env: String? = nil) -> Int32 {
    let scope = d1 == .remote ? " (remote D1)" : ""
    if migrate {
        print("→ Migrating\(scope)")
        let status = migrateCommand(path: path, d1: d1, dbName: nil, assumeYes: true, env: env)
        if status != 0 { return status }
    }
    if seed {
        print("→ Seeding\(scope)")
        let status = seedCommand(path: path, d1: d1, dbName: nil, assumeYes: true, env: env)
        if status != 0 { return status }
    }
    return 0
}

private func deployCloudflare(path: String, outDir: String, migrate: Bool, seed: Bool,
                              env: String?) -> Int32 {
    // Build first: applying migrations/seeds to a remote D1 goes through the bundle's
    // wrangler.toml, which only exists after the build.
    let built = buildCloudflareCommand(path: path, outDir: outDir, env: env, showNextSteps: false)
    if built != 0 { return built }
    let data = deployDataSteps(path: path, d1: .remote, migrate: migrate, seed: seed, env: env)
    if data != 0 { return data }

    let bundleDir = cloudflareBundleDir(path: path, outDir: outDir, env: env)
    guard let config = WranglerConfig.load(bundleDir + "/wrangler.toml") else {
        errorLine("could not read \(bundleDir)/wrangler.toml")
        return 1
    }
    guard let api = CloudflareAPI.resolve(config: config) else {
        errorLine("Cloudflare auth needed to deploy. Set CLOUDFLARE_API_TOKEN, run `plumekit login`,")
        errorLine("or `wrangler login` (an active session is reused). An account id must also be")
        errorLine("available: [targets.cloudflare] account_id, CLOUDFLARE_ACCOUNT_ID, or the login default.")
        return 1
    }
    warnMissingCloudflareSecrets(bundleDir: bundleDir)
    return deployCloudflareViaAPI(projectRoot: path, bundleDir: bundleDir, api: api, config: config,
                                  env: env)
}

/// Warn before deploying if the signing secrets aren't set on the Cloudflare side —
/// a deploy without them runs with no real signing key. Best-effort: never blocks.
private func warnMissingCloudflareSecrets(bundleDir: String) {
    let required = ["CSRF_SECRET", "CHANNEL_SIGNING_KEY", "AUTH_SECRET"]
    guard let config = WranglerConfig.load(bundleDir + "/wrangler.toml"),
          let api = CloudflareAPI.resolve(config: config), let script = config.name,
          let configured = api.listSecrets(script: script) else { return }
    let missing = required.filter { !configured.contains($0) }
    guard !missing.isEmpty else { return }
    errorLine("Warning: these signing secrets are not set on Cloudflare: \(missing.joined(separator: ", ")).")
    errorLine("Set each before serving traffic, e.g.  plumekit secret set \(missing[0])")
    errorLine("Without them the worker has no signing key and CSRF / channel tokens are insecure.")
}

// MARK: - Secrets

/// `plumekit secret set NAME [--env E] [path]` / `plumekit secret list [--env E]
/// [path]` — the deploy secrets for the app's target (dispatched per provider;
/// cloudflare implemented). With `--env`, the environment's own worker — every
/// environment keeps a separate secret store.
/// The value is read from a hidden prompt (or stdin when piped), never from argv.
func secretCommand(arguments: [String]) -> Int32 {
    guard let parsed = parseOptions(arguments, command: "secret",
                                    valueSpellings: ["--env": "env"]) else { return 1 }
    let env = parsed.values["env"]
    switch parsed.positionals.first {
    case "list":
        let path = parsed.positionals.dropFirst().first ?? "."
        guard let (api, script) = secretsTarget(path: path, env: env) else { return 1 }
        guard let names = api.listSecrets(script: script) else {
            errorLine("could not list secrets — has \"\(script)\" been deployed yet?")
            return 1
        }
        for name in names.sorted() { print(name) }
        return 0
    case "set":
        guard parsed.positionals.count >= 2 else {
            errorLine("usage: plumekit secret set NAME [--env E] [path]")
            return 1
        }
        let name = parsed.positionals[1]
        let path = parsed.positionals.count > 2 ? parsed.positionals[2] : "."
        guard let (api, script) = secretsTarget(path: path, env: env) else { return 1 }
        guard let value = readSecretValue(prompt: "Value for \(name) (hidden): "), !value.isEmpty else {
            errorLine("no value given")
            return 1
        }
        guard api.putSecret(script: script, name: name, value: value) else {
            errorLine("setting \(name) failed — the worker must exist (deploy once first), and the "
                      + "token needs the Workers Scripts edit permission")
            return 1
        }
        print(Style.green("✓") + " \(name) set on \"\(script)\"")
        return 0
    default:
        errorLine("usage: plumekit secret set NAME [--env E] [path] | plumekit secret list [--env E] [path]")
        return 1
    }
}

private func secretsTarget(path: String, env: String?) -> (CloudflareAPI, String)? {
    let provider = defaultProvider(path: path)
    guard provider == "cloudflare" else {
        if provider == "aws" {
            errorLine("the aws target keeps secrets in SSM (`secrets = \"ssm\"`) — set them with `aws ssm put-parameter`.")
        } else {
            errorLine("the \(provider) target reads secrets from the environment (.env) — nothing to set remotely.")
        }
        return nil
    }
    if let env, !validateDeclaredEnvironment(projectPath: path, target: provider, env: env) {
        return nil
    }
    let settings = CloudflareSettings.read(projectPath: path, projectName: projectName(path), env: env)
    guard let api = CloudflareAPI.resolve(accountId: settings.accountId) else {
        errorLine("Cloudflare auth needed: set CLOUDFLARE_API_TOKEN, run `plumekit login`, "
                  + "or `wrangler login` (an active session is reused).")
        return nil
    }
    return (api, settings.name)
}

func readSecretValue(prompt: String) -> String? {
    if isatty(STDIN_FILENO) == 0 {
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
    var raw = termios()
    tcgetattr(STDIN_FILENO, &raw)
    let original = raw
    raw.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer {
        var restore = original
        tcsetattr(STDIN_FILENO, TCSANOW, &restore)
        print("")
    }
    print(prompt, terminator: "")
    return readLine()
}

private func deployAWS(path: String, outDir: String, migrate: Bool, seed: Bool,
                       env: String?) -> Int32 {
    if let env, !validateDeclaredEnvironment(projectPath: path, target: "aws", env: env) {
        return 1
    }
    // Data steps run through the app's runMigrations/runSeed against the configured
    // database (point [targets.native] at postgres + DATABASE_URL to target RDS).
    let data = deployDataSteps(path: path, d1: nil, migrate: migrate, seed: seed)
    if data != 0 { return data }
    let built = buildAWSCommand(path: path, outDir: outDir, showNextSteps: false)
    if built != 0 { return built }

    guard toolExists("aws") else {
        errorLine("the aws CLI is not installed — needed to update the Lambda function code.")
        return 1
    }
    // An environment deploys the same bundle to its own function, "<name>-<env>".
    // An explicit AWS_FUNCTION_NAME wins verbatim — it names the exact function.
    // The function's config (env vars, its own database) is the user's, per environment.
    let function = ProcessInfo.processInfo.environment["AWS_FUNCTION_NAME"]
        ?? (env.map { "\(projectName(path))-\($0)" } ?? projectName(path))
    let zip = path + "/" + outDir + "/aws/function.zip"
    print("→ Deploying (aws lambda update-function-code → \(function))")
    return runInherit("aws", ["lambda", "update-function-code",
                              "--function-name", function, "--zip-file", "fileb://\(zip)"])
}

private func deployNative(path: String, migrate: Bool, seed: Bool, env: String?) -> Int32 {
    if let env, !validateDeclaredEnvironment(projectPath: path, target: "native", env: env) {
        return 1
    }
    let data = deployDataSteps(path: path, d1: nil, migrate: migrate, seed: seed)
    if data != 0 { return data }
    guard toolExists("docker") else {
        errorLine("docker is not installed — needed to build the container image.")
        return 1
    }
    let name = env.map { "\(projectName(path))-\($0)" } ?? projectName(path)
    print("→ docker build -t \(name)")
    let status = runInherit("docker", ["build", "-t", name, "."], cwd: path)
    if status != 0 { return status }
    print("")
    print("✓ Built image '\(name)'. Push and run it on your host:")
    print("  docker push \(name)   ·   fly deploy   ·   your platform's deploy step")
    return 0
}

// MARK: - env / doctor / dev / routes

/// The KEY=VALUE pairs of <path>/.env, in file order (empty when there is none).
func parseDotEnv(projectPath: String) -> [(key: String, value: String)] {
    guard let contents = try? String(contentsOfFile: projectPath + "/.env", encoding: .utf8) else { return [] }
    let ws = CharacterSet.whitespacesAndNewlines   // trims CR too, so CRLF files work
    var pairs: [(key: String, value: String)] = []
    for raw in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
        var line = raw.trimmingCharacters(in: ws)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: ws)
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: ws)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())   // quoted values keep '#' and spaces verbatim
        } else if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: ws)   // strip an inline comment
        }
        pairs.append((key, value))
    }
    return pairs
}

/// Load <path>/.env into the environment (existing env always wins), so
/// serve/migrate/dev pick up DATABASE_URL, secrets, etc. without hand-exporting.
func loadDotEnv(projectPath: String) {
    for (key, value) in parseDotEnv(projectPath: projectPath)
    where ProcessInfo.processInfo.environment[key] == nil {
        setenv(key, value, 0)
    }
}

/// `plumekit doctor` — report which per-target tools are installed.
func doctorCommand() -> Int32 {
    print("PlumeKit environment")
    let swiftLine = capture("swift", ["--version"]).output
        .split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "swift"
    print("  ✓ \(swiftLine)")
    func check(_ ok: Bool, _ label: String, _ need: String) {
        print(ok ? "  ✓ \(label)" : "  ✗ \(label) — \(need)")
    }
    check(embeddedWasmSDK() != nil, "Embedded WebAssembly SDK", "installed automatically on the first `build --target cloudflare`")
    check(cachedWasmOpt() != nil, "wasm-opt (binaryen)", "fetched automatically on the first Cloudflare build")
    check(cloudflareToken() != nil,
          "Cloudflare auth", "for deploy: CLOUDFLARE_API_TOKEN, `plumekit login`, or an active `wrangler login`")
    check(toolExists("node"), "node", "for the Cloudflare runtime")
    check(capture("pkg-config", ["--exists", "libpq"]).status == 0, "libpq", "for the Postgres driver (brew install libpq)")
    check(toolExists("aws"), "aws CLI", "for AWS Lambda deploy")
    check(toolExists("docker"), "docker", "for the native container image / LocalStack")
    return 0
}

/// `plumekit routes` — list the app's registered routes (runs the Server with --routes).
func routesCommand(path: String) -> Int32 {
    runAppServer(path: path, ["--routes"])
}

/// `plumekit dev` — serve natively, rebuilding + restarting on source/template changes.
/// The rebuild runs while the OLD server keeps serving; only a successful build swaps
/// it. A broken save shows the compile error here and leaves the last working server
/// up, instead of tearing it down and answering connection refused until it's fixed.
func devCommand(path: String, host: String, port: UInt16) -> Int32 {
    // The child's environment is rebuilt per spawn as baseline + a fresh `.env`
    // overlay (baseline wins — a var the user exported in their shell must never
    // be clobbered by the file). Rebuilding per spawn also means an edited or
    // REMOVED `.env` value takes effect on the next restart, which mutating this
    // process's own environment could never undo.
    let baseline = ProcessInfo.processInfo.environment
    func childEnvironment() -> [String: String] {
        var env = baseline
        for (key, value) in parseDotEnv(projectPath: path) where baseline[key] == nil {
            env[key] = value
        }
        if env["PLUMEKIT_ENV"] == nil { env["PLUMEKIT_ENV"] = "development" }   // dev error page
        return env
    }
    print("→ plumekit dev — watching Sources/, Views/, Translations/, plumekit.toml, .env (ctrl-c to stop)")
    var server: Process?

    func rebuildAndSwap() {
        if compileTemplates(projectPath: path) != 0 {
            print("✗ template compile failed — keeping the previous server running")
            return
        }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--package-path", path, "--product", "Server"]
        do { try build.run() } catch {
            print("✗ could not run swift build: \(error)")
            return
        }
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            print("✗ build failed — keeping the previous server running")
            return
        }
        if let old = server {
            old.terminate()
            old.waitUntilExit()   // reap — a dev session mustn't accumulate zombies
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // The product was just built, so this run's build step is a no-op check.
        process.arguments = ["swift", "run", "--package-path", path, "Server",
                             "--host", host, "--port", String(port)]
        process.environment = childEnvironment()
        do { try process.run(); server = process } catch {
            print("✗ could not start the server: \(error)")
        }
    }

    rebuildAndSwap()
    var snapshot = watchSnapshot(path)
    while true {
        Thread.sleep(forTimeInterval: 1.0)
        let current = watchSnapshot(path)
        if current != snapshot {
            snapshot = current
            print("↻ change detected — rebuilding…")
            rebuildAndSwap()
        }
    }
}

private func watchSnapshot(_ path: String) -> [String: Date] {
    var result: [String: Date] = [:]
    let fm = FileManager.default
    for dir in ["Sources", "Views", "Templates", "Translations"] {
        let base = path + "/" + dir
        guard let enumerator = fm.enumerator(atPath: base) else { continue }
        for case let file as String in enumerator
        where file.hasSuffix(".swift") || file.hasSuffix(".plume") || file.hasSuffix(".json") {
            let full = base + "/" + file
            if let m = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date {
                result[full] = m
            }
        }
    }
    // Config the codegen plugin and the runtime read: flipping a capability or
    // editing an env value must restart too — that's exactly the workflow the
    // capability prompts point people at.
    for file in ["plumekit.toml", ".env", ".dev.vars"] {
        let full = path + "/" + file
        if let m = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date {
            result[full] = m
        }
    }
    return result
}

// MARK: - console / test

func consoleCommand(path: String) -> Int32 {
    print("→ plumekit console — building & starting the REPL")
    return runAppServer(path: path, ["--console"])
}

// MARK: - generate (scaffolding)

func generateCommand(arguments: [String]) -> Int32 {
    let usage = "usage: plumekit generate <resource|model|controller|migration|view|middleware|job|seeder|test|auth|notifications|ci> … [--path <dir>]"
    var arguments = arguments

    // Generators write project-relative paths, so they run from the project root —
    // but reach it themselves: `--path` names it explicitly, and otherwise walk up
    // from the working directory (Rails-style: generate works from a subdirectory).
    var projectRoot: String?
    if let flagIndex = arguments.firstIndex(where: { $0 == "--path" }) {
        guard flagIndex + 1 < arguments.count else { errorLine("--path needs a value"); return 1 }
        projectRoot = arguments[flagIndex + 1]
        arguments.removeSubrange(flagIndex...(flagIndex + 1))
    } else if !FileManager.default.fileExists(atPath: "Sources/App") {
        var candidate = FileManager.default.currentDirectoryPath
        while candidate != "/" {
            if FileManager.default.fileExists(atPath: candidate + "/Sources/App") {
                projectRoot = candidate
                break
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }
    if let projectRoot {
        guard FileManager.default.changeCurrentDirectoryPath(projectRoot) else {
            errorLine("cannot enter project directory '\(projectRoot)'")
            return 1
        }
    }

    guard let kind = arguments.first else { errorLine(usage); return 1 }

    // These write into an existing project and take no <Name>.
    if kind == "ci" { return generateCI(arguments: Array(arguments.dropFirst())) }
    if kind == "auth" || kind == "notifications" {
        guard FileManager.default.fileExists(atPath: "Sources/App") else {
            errorLine("run `plumekit generate` from a project root (no Sources/App found)")
            return 1
        }
        if kind == "auth" {
            guard ensureCapabilities(authRequiredCapabilities, for: "generate auth") else { return 1 }
            return generateAuth()
        }
        return generateNotifications()
    }

    guard arguments.count >= 2 else { errorLine(usage); return 1 }
    let name = arguments[1]
    let fields = Array(arguments.dropFirst(2))

    guard FileManager.default.fileExists(atPath: "Sources/App") else {
        errorLine("run `plumekit generate` from a project root (no Sources/App found)")
        return 1
    }

    // A generated model that queries a database the app doesn't have kills the
    // process (`Database.current` traps) — catch it at generate time instead.
    if kind == "resource" || kind == "model" {
        guard ensureCapabilities(modelRequiredCapabilities, for: "generate \(kind)") else { return 1 }
    }

    switch kind {
    case "resource":   return generateResource(name: name, fields: fields)
    case "model":      return generateModel(name: name, fields: fields)
    case "controller": return generateController(name: name)
    case "migration":  return generateMigration(name: name)
    case "view":       return generateView(name: name)
    case "middleware": return generateMiddleware(name: name)
    case "job":        return generateJob(name: name)
    case "seeder":     return generateSeeder(name: name)
    case "test":       return generateTest(name: name)
    default:
        errorLine("unknown generator '\(kind)'")
        errorLine(usage)
        return 1
    }
}

/// Check the project has the capabilities a generator's output needs; offer to flip
/// them in plumekit.toml at a TTY, otherwise print the exact lines to change. Returns
/// false (after printing why) when generation should not proceed.
private func ensureCapabilities(_ needed: [String], for what: String) -> Bool {
    let config = BuildConfig.read(projectPath: ".")
    let missing = needed.filter { !config.hasCapability($0) }
    if missing.isEmpty { return true }

    let list = missing.map { "`\($0)`" }.joined(separator: ", ")
    print("\(what) needs the \(list) capabilit\(missing.count == 1 ? "y" : "ies"), which this app has disabled.")
    if Prompt.isInteractive, Prompt.confirm("Enable in plumekit.toml now?") {
        guard enableCapabilities(missing, tomlPath: "plumekit.toml") else {
            errorLine("could not update plumekit.toml — enable \(list) there manually")
            return false
        }
        for name in missing { print("  plumekit.toml: \(name) = true") }
        linkDriverDependencies(for: missing)
        return true
    }
    errorLine("enable \(missing.map { "\($0) = true" }.joined(separator: ", ")) under [capabilities] in plumekit.toml, then re-run")
    return false
}

/// Which capabilities pull a driver product into the Lambda target. ONE home for
/// this mapping on the CLI side — the scaffold's Package template and the
/// enable-time patcher below both read it (plumekit-codegen keeps its own copy;
/// it is deliberately dependency-free).
let lambdaDriverProducts: [(capability: String, product: String)] = [
    ("database", "PlumePostgres"), ("storage", "PlumeS3"),
]

/// Newly enabled capabilities can need driver products the scaffold only linked
/// when they were on at `plumekit new` time. Patch Package.swift's Lambda
/// dependencies so "flip a capability + rebuild" keeps its promise; if the file
/// has been reshaped beyond recognition, say exactly what to add instead.
private func linkDriverDependencies(for capabilities: [String]) {
    let needed = lambdaDriverProducts.filter { pair in capabilities.contains { $0 == pair.capability } }
    guard !needed.isEmpty,
          var manifest = try? String(contentsOfFile: "Package.swift", encoding: .utf8) else { return }

    let anchor = #".product(name: "PlumeAWS", package: "PlumeKit")"#
    var changed = false
    for (_, product) in needed {
        let productRef = ".product(name: \"\(product)\", package: \"PlumeKit\")"
        if manifest.contains(productRef) { continue }
        if manifest.contains(anchor) {
            manifest = manifest.replacingOccurrences(of: anchor, with: anchor + ", " + productRef)
            changed = true
            print("  Package.swift: linked \(product) into the Lambda target")
        } else {
            print("  Add \(productRef) to the Lambda target's dependencies in Package.swift.")
        }
    }
    if changed {
        try? manifest.write(toFile: "Package.swift", atomically: true, encoding: .utf8)
    }
}

/// Flip (or insert) `<name> = true` lines under `[capabilities]` in the toml file.
private func enableCapabilities(_ names: [String], tomlPath: String) -> Bool {
    guard var toml = try? String(contentsOfFile: tomlPath, encoding: .utf8) else { return false }
    var lines = toml.components(separatedBy: "\n")
    var remaining = Set(names)
    var section = ""
    var capabilitiesHeaderIndex: Int? = nil
    for (index, raw) in lines.enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast())
            if section == "capabilities" { capabilitiesHeaderIndex = index }
            continue
        }
        guard section == "capabilities", let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        if remaining.contains(key) {
            lines[index] = "\(key) = true"
            remaining.remove(key)
        }
    }
    if !remaining.isEmpty {
        // No existing line to flip — insert after the [capabilities] header, or
        // append a fresh table.
        let inserted = remaining.sorted().map { "\($0) = true" }
        if let headerIndex = capabilitiesHeaderIndex {
            lines.insert(contentsOf: inserted, at: headerIndex + 1)
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append(contentsOf: ["", "[capabilities]"] + inserted + [""])
        }
    }
    toml = lines.joined(separator: "\n")
    return (try? toml.write(toFile: tomlPath, atomically: true, encoding: .utf8)) != nil
}

/// `plumekit generate ci --provider <github|gitlab|forgejo>` — CI workflows that test
/// on PRs and run `./plumekit deploy` on push to main (tailored to the [build] target).
private func generateCI(arguments: [String]) -> Int32 {
    var provider = "github"
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--provider", index + 1 < arguments.count {
            provider = arguments[index + 1]; index += 1
        }
        index += 1
    }

    let config = BuildConfig.read(projectPath: ".")
    let target = config.defaultTarget ?? config.targets.first ?? "cloudflare"

    let capabilities: Set<String> = config.hasCapability("database") ? ["database"] : []
    guard let files = CITemplates.files(provider: provider, target: target,
                                        capabilities: capabilities) else {
        errorLine("unknown CI provider '\(provider)' (have: github, gitlab, forgejo)")
        return 1
    }
    for (filePath, contents) in files {
        let dir = (filePath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !writeFile(contents, to: filePath) { return 1 }
        print("  + \(filePath)")
    }
    print("✓ \(provider) CI: test on PR → main, deploy (\(target)) on push → main.")
    print("  Set the secrets referenced in the deploy workflow in your repo settings.")
    return 0
}

// The individual generators live in Generators.swift; the auth scaffold in
// AuthGenerator.swift.

// Which database `migrate`/`seed` target. `nil` is the app's own configured
// database (plumekit.toml); the D1 cases go through wrangler.
enum D1Target { case local, remote }

func migrateCommand(path: String, d1: D1Target?, dbName: String?, assumeYes: Bool,
                    env: String? = nil) -> Int32 {
    loadDotEnv(projectPath: path)
    if let d1 {
        return migrateD1(path: path, d1: d1, dbName: dbName, assumeYes: assumeYes, env: env)
    }
    guard env == nil else {
        errorLine("--env targets a deploy environment's D1 — pass --local or --remote with it.")
        return 1
    }
    // Native: the app's Server binary applies migrations under --migrate (it holds
    // the migration list).
    print("→ plumekit migrate — applying pending schema changes")
    return runAppServer(path: path, ["--migrate"])
}

/// The shared prologue for commands that run the app's Server binary: load .env,
/// compile templates (a freshly generated resource references views that don't
/// exist as Swift yet), then `swift run Server <arguments>`.
private func runAppServer(path: String, _ serverArguments: [String]) -> Int32 {
    loadDotEnv(projectPath: path)
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }
    return runInherit("swift", ["run", "--package-path", path, "Server"] + serverArguments)
}

/// The new migrate subcommands ride Server flags that apps scaffolded before them
/// don't parse — and an old Server main falls through unknown flags and BOOTS THE
/// HTTP SERVER. Check the (user-owned, never regenerated) entry point mentions the
/// flag before running, and say what to add when it doesn't.
private func serverSupportsFlag(_ flag: String, path: String) -> Bool {
    guard let main = try? String(contentsOfFile: path + "/Sources/Server/main.swift",
                                 encoding: .utf8) else {
        return true   // unusual layout — don't block; worst case the server prints usage
    }
    return main.contains(flag)
}

/// `plumekit migrate --rollback [N]` — reverse the newest N applied migrations
/// (their `down:` blocks) against the native database.
func migrateRollbackCommand(path: String, steps: Int, d1: D1Target?) -> Int32 {
    guard d1 == nil else {
        errorLine("migrate --rollback works against the native database only — D1 migrations")
        errorLine("are applied as forward-only SQL batches (write a new migration to undo).")
        return 1
    }
    guard serverSupportsFlag("--rollback", path: path) else {
        errorLine("this app's Sources/Server/main.swift predates `migrate --rollback`.")
        errorLine("Add the `--rollback` / `--migration-status` flags there (a freshly scaffolded")
        errorLine("app's Server main shows the shape), then re-run.")
        return 1
    }
    print("→ plumekit migrate --rollback — reversing the last \(steps) migration(s)")
    return runAppServer(path: path, ["--rollback", String(steps)])
}

/// `plumekit migrate --status` — each migration and whether it has been applied.
func migrateStatusCommand(path: String, d1: D1Target?) -> Int32 {
    guard d1 == nil else {
        errorLine("migrate --status works against the native database — for D1, `plumekit migrate")
        errorLine("--local|--remote` already reports the target ledger before applying.")
        return 1
    }
    guard serverSupportsFlag("--migration-status", path: path) else {
        errorLine("this app's Sources/Server/main.swift predates `migrate --status`.")
        errorLine("Add the `--migration-status` / `--rollback` flags there (a freshly scaffolded")
        errorLine("app's Server main shows the shape), then re-run.")
        return 1
    }
    return runAppServer(path: path, ["--migration-status"])
}

func seedCommand(path: String, only: String? = nil, d1: D1Target?, dbName: String?, assumeYes: Bool,
                 env: String? = nil) -> Int32 {
    loadDotEnv(projectPath: path)
    if let d1 {
        return applyToD1(path: path, verb: "seed", dumpMode: "seed", only: only, d1: d1, dbName: dbName,
                         assumeYes: assumeYes, env: env)
    }
    guard env == nil else {
        errorLine("--env targets a deploy environment's D1 — pass --local or --remote with it.")
        return 1
    }
    print("→ plumekit seed — inserting seed data\(only.map { " (\($0))" } ?? "")")
    var args = ["--seed"]
    if let only { args.append(only) }
    return runAppServer(path: path, args)
}

// wrangler must never block on an interactive prompt it can't reach: a wrangler that
// stops to ask (multiple Cloudflare accounts and none pinned, first-run telemetry
// consent, not logged in) gets SIGTTIN-suspended and hangs the whole deploy silently.
// `CI=1` makes wrangler refuse to prompt and exit non-zero with a message instead;
// disabling metrics skips the first-run consent prompt. Applied ONLY to wrangler spawns
// (never the swift build/run spawns).
private let wranglerEnv = ["CI": "1", "WRANGLER_SEND_METRICS": "false"]

/// Heads-up before a `--remote` wrangler op when no Cloudflare account is pinned: a
/// login with more than one account can't be resolved non-interactively, so wrangler
/// will fail. Best-effort — never blocks.
private func warnIfNoCloudflareAccount(wranglerToml: String) {
    let envSet = ProcessInfo.processInfo.environment["CLOUDFLARE_ACCOUNT_ID"]?.isEmpty == false
    if envSet || wranglerTomlHasAccountID(wranglerToml) { return }
    FileHandle.standardError.write(Data(
        ("note: no Cloudflare account pinned — if your login has more than one account, wrangler "
       + "can't pick one non-interactively and will fail. Pin one via `account_id = \"…\"` in "
       + "wrangler.toml or the CLOUDFLARE_ACCOUNT_ID env var.\n").utf8))
}

/// Does the generated wrangler.toml declare an `account_id`?
private func wranglerTomlHasAccountID(_ tomlPath: String) -> Bool {
    guard let toml = try? String(contentsOfFile: tomlPath, encoding: .utf8) else { return false }
    for rawLine in toml.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("account_id"), line.contains("=") { return true }
    }
    return false
}

/// One-line hint appended when a remote wrangler command exits non-zero — the usual
/// causes are an unauthenticated session or an unpinned account.
private func wranglerFailureHint() {
    FileHandle.standardError.write(Data(
        ("hint: wrangler failed. Check you're logged in (`wrangler login`, or set CLOUDFLARE_API_TOKEN) "
       + "and, with multiple Cloudflare accounts, pin one (`account_id` in wrangler.toml or "
       + "CLOUDFLARE_ACCOUNT_ID).\n").utf8))
}

/// The `version: "…"` string literals declared by the files in
/// Sources/App/Database/Migrations — the same files codegen turns into the Server's
/// migration registry. Returns nil when a file contains no such literal (a computed
/// version), so callers fall back to asking the built Server for the real list.
private func declaredMigrationVersions(projectPath: String) -> [String]? {
    let dir = projectPath + "/Sources/App/Database/Migrations"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    var versions: [String] = []
    for file in files where file.hasSuffix(".swift") {
        guard let source = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { return nil }
        var found = false
        var rest = source[...]
        while let marker = rest.range(of: "version:") {
            rest = rest[marker.upperBound...]
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.first == "\"" else { continue }
            let body = trimmed.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { break }
            versions.append(String(body[..<close]))
            rest = body[body.index(after: close)...]
            found = true
        }
        if !found { return nil }
    }
    return versions
}

// Ledger-aware `migrate --local|--remote`: apply ONLY the pending migrations to a
// Cloudflare D1, honouring its `schema_migrations` ledger. Read the versions already
// applied on the target, ask the native Server for those migrations' real up() SQL
// (the wasm worker can't run migrations), and let wrangler load it. This replaces the
// old full-schema `CREATE TABLE IF NOT EXISTS` dump, which was additive-only — an
// ALTER on an existing table never landed.
private func migrateD1(path: String, d1: D1Target, dbName: String?, assumeYes: Bool,
                       env: String? = nil) -> Int32 {
    if let env, !validateDeclaredEnvironment(projectPath: path, target: "cloudflare", env: env) {
        return 1
    }
    let bundleDir = cloudflareBundleDir(path: path, outDir: BuildConfig.read(projectPath: path).out, env: env)
    let wranglerToml = bundleDir + "/wrangler.toml"
    guard FileManager.default.fileExists(atPath: wranglerToml) else {
        let envFlag = env.map { " --env \($0)" } ?? ""
        errorLine("no \(wranglerToml) — run `plumekit build --target cloudflare\(envFlag) \(path)` first")
        return 1
    }
    let remote = d1 == .remote

    // Remote D1 goes over the Cloudflare API when a token is present (resolving —
    // or first creating — the database by name when no id is pinned). `--local`
    // always goes through wrangler — the local D1 lives in its simulator state.
    var apiTransport: (api: CloudflareAPI, databaseId: String)?
    if remote {
        switch remoteD1Transport(projectPath: path, bundleToml: wranglerToml, dbName: dbName, env: env) {
        case .api(let api, let databaseId): apiTransport = (api, databaseId)
        case .failed: return 1
        case .none:
            errorLine("Cloudflare auth needed for --remote: set CLOUDFLARE_API_TOKEN, "
                      + "run `plumekit login`, or `wrangler login` (an active session is reused).")
            return 1
        }
    }

    let wranglerTool = toolExists("wrangler") ? "wrangler" : "npx"
    guard apiTransport != nil || toolExists("wrangler") || toolExists("npx") else {
        errorLine("wrangler not found — the local D1 simulator needs it (`npm i -D wrangler`)")
        return 1
    }
    guard let database = dbName ?? wranglerDatabaseName(wranglerToml) else {
        errorLine("no d1 database_name in \(wranglerToml); pass --db NAME")
        return 1
    }
    let wranglerArgs = wranglerTool == "npx" ? ["wrangler"] : []

    let scope = remote ? "--remote" : "--local"
    if remote {
        FileHandle.standardError.write(Data(
            "⚠️  plumekit migrate --remote targets the LIVE D1 \"\(database)\".\n".utf8))
        warnIfNoCloudflareAccount(wranglerToml: wranglerToml)
    }

    // 1. Read the target's ledger. Fail CLOSED: treating a wrangler crash, auth failure
    //    or unparseable output as "nothing applied" would replay every migration —
    //    InitialSchema included — against a live database. The only benign read failure
    //    is a fresh D1 with no schema_migrations table yet, so that exact case is
    //    confirmed against sqlite_master before proceeding; anything else aborts.
    func ledgerQuery(_ sql: String, column: String) -> (status: Int32, rows: [String]?) {
        if let (api, databaseId) = apiTransport {
            guard let result = api.d1Query(databaseId: databaseId, sql: sql),
                  let rows = result.first?["results"] as? [[String: Any]] else { return (1, nil) }
            return (0, rows.compactMap { row in
                (row[column] as? String) ?? (row[column] as? Int).map(String.init)
            })
        }
        var args = wranglerArgs + ["d1", "execute", database, scope, "--json", "--command", sql]
        if assumeYes { args.append("--yes") }
        let run = captureStdout(wranglerTool, args, cwd: bundleDir, env: wranglerEnv)
        guard run.status == 0 else { return (run.status, nil) }
        return (0, parseD1Column(run.output, column: column))
    }

    let appliedVersions: [String]
    let ledger = ledgerQuery("SELECT version FROM schema_migrations ORDER BY version", column: "version")
    if let versions = ledger.rows {
        appliedVersions = versions
    } else if ledger.status == 0 {
        errorLine("could not parse wrangler's schema_migrations output for \"\(database)\" — aborting rather than treating it as a fresh database")
        return 1
    } else {
        let probe = ledgerQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'",
            column: "name")
        guard let tables = probe.rows else {
            errorLine("reading the schema_migrations ledger of \"\(database)\" failed — aborting rather than treating it as a fresh database")
            if remote && apiTransport == nil { wranglerFailureHint() }
            return ledger.status
        }
        guard tables.isEmpty else {
            errorLine("\"\(database)\" has a schema_migrations table but reading it failed — aborting rather than treating it as a fresh database")
            if remote && apiTransport == nil { wranglerFailureHint() }
            return ledger.status
        }
        appliedVersions = []    // confirmed fresh: no ledger table yet
    }

    // 2. Fast path: when every migration declared in the sources is already in the
    //    ledger there is nothing to compute, so skip building the native Server (a
    //    full cold build on CI). Falls through to the build whenever a migration
    //    file doesn't declare its version as a plain string literal.
    if let declared = declaredMigrationVersions(projectPath: path),
       Set(declared).subtracting(appliedVersions).isEmpty {
        FileHandle.standardError.write(Data("→ already up to date (\(appliedVersions.count) applied)\n".utf8))
        return 0
    }

    // 3. Ask the native Server for the pending migrations' SQL (build logs → stderr).
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }
    let appliedFile = bundleDir + "/.plumekit-applied.txt"
    guard writeFile(appliedVersions.joined(separator: "\n"), to: appliedFile) else {
        errorLine("could not write \(appliedFile)")
        return 1
    }
    defer { try? FileManager.default.removeItem(atPath: appliedFile) }

    print("→ plumekit migrate \(scope) — computing pending migrations for \"\(database)\" (\(appliedVersions.count) already applied)")
    let dump = captureStdout("swift", ["run", "--package-path", path, "Server",
                                       "--dump-sql", "pending", appliedFile])
    guard dump.status == 0 else {
        errorLine("computing pending migrations failed (Server --dump-sql pending exited \(dump.status))")
        return dump.status
    }

    // 4. The Server prefixes a `-- plumekit-pending: v1,v2` comment (harmless SQL) so we
    //    know which versions will apply — and can skip wrangler when none are pending.
    let pending = parsePendingHeader(dump.output)
    if pending.isEmpty {
        FileHandle.standardError.write(Data("→ already up to date (\(appliedVersions.count) applied)\n".utf8))
        return 0
    }

    print("→ applying \(pending.count) migration(s): \(pending.joined(separator: ", "))")
    if let (api, databaseId) = apiTransport {
        guard api.d1Query(databaseId: databaseId, sql: dump.output) != nil else { return 1 }
        return 0
    }

    let sqlFile = bundleDir + "/.plumekit-migrate.sql"
    guard writeFile(dump.output, to: sqlFile) else {
        errorLine("could not write \(sqlFile)")
        return 1
    }
    defer { try? FileManager.default.removeItem(atPath: sqlFile) }

    var args = wranglerArgs + ["d1", "execute", database, scope, "--file", ".plumekit-migrate.sql"]
    if assumeYes { args.append("--yes") }
    let status = runInherit(wranglerTool, args, cwd: bundleDir, env: wranglerEnv)
    if remote && status != 0 { wranglerFailureHint() }
    return status
}

/// One column's values from `wrangler d1 execute --json` output. wrangler emits
/// `[{"results":[{"<column>":"…"}, …], …}]` (one object per statement). Returns nil
/// when the output isn't that shape at all — the caller must NOT mistake a broken
/// read for an empty result; a parsed statement with zero rows returns [].
private func parseD1Column(_ json: String, column: String) -> [String]? {
    guard let data = json.data(using: .utf8),
          let top = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let objects: [Any] = (top as? [Any]) ?? [top]
    var values: [String] = []
    var sawResults = false
    for obj in objects {
        guard let dict = obj as? [String: Any], let results = dict["results"] as? [Any] else { continue }
        sawResults = true
        for row in results {
            if let rowDict = row as? [String: Any], let v = rowDict[column] as? String { values.append(v) }
        }
    }
    return sawResults ? values : nil
}

/// The `-- plumekit-pending: v1,v2` header the Server prints ahead of the pending SQL.
/// An empty list (or no header) means the target is already up to date.
private func parsePendingHeader(_ sql: String) -> [String] {
    let marker = "-- plumekit-pending:"
    for rawLine in sql.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(marker) else { continue }
        let list = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if list.isEmpty { return [] }
        return list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    return []
}

// Apply a slice of the app's schema/seed to a Cloudflare D1: the native Server
// dumps it as SQL (it can't run in the wasm worker), and wrangler loads it. One
// command in place of `Server --dump-sql … > f.sql && wrangler d1 execute … -f f.sql`.
private func applyToD1(path: String, verb: String, dumpMode: String, only: String? = nil,
                       d1: D1Target, dbName: String?, assumeYes: Bool, env: String? = nil) -> Int32 {
    if let env, !validateDeclaredEnvironment(projectPath: path, target: "cloudflare", env: env) {
        return 1
    }
    let bundleDir = cloudflareBundleDir(path: path, outDir: BuildConfig.read(projectPath: path).out, env: env)
    let wranglerToml = bundleDir + "/wrangler.toml"
    guard FileManager.default.fileExists(atPath: wranglerToml) else {
        let envFlag = env.map { " --env \($0)" } ?? ""
        errorLine("no \(wranglerToml) — run `plumekit build --target cloudflare\(envFlag) \(path)` first")
        return 1
    }
    let remote = d1 == .remote

    // Same transport rule as migrate: --remote over the Cloudflare API when a token
    // is present, wrangler otherwise; --local always through wrangler's simulator.
    var apiTransport: (api: CloudflareAPI, databaseId: String)?
    if remote {
        switch remoteD1Transport(projectPath: path, bundleToml: wranglerToml, dbName: dbName, env: env) {
        case .api(let api, let databaseId): apiTransport = (api, databaseId)
        case .failed: return 1
        case .none:
            errorLine("Cloudflare auth needed for --remote: set CLOUDFLARE_API_TOKEN, "
                      + "run `plumekit login`, or `wrangler login` (an active session is reused).")
            return 1
        }
    }

    let wranglerTool = toolExists("wrangler") ? "wrangler" : "npx"
    guard apiTransport != nil || toolExists("wrangler") || toolExists("npx") else {
        errorLine("wrangler not found — the local D1 simulator needs it (`npm i -D wrangler`)")
        return 1
    }
    guard let database = dbName ?? wranglerDatabaseName(wranglerToml) else {
        errorLine("no d1 database_name in \(wranglerToml); pass --db NAME")
        return 1
    }

    let scope = remote ? "--remote" : "--local"
    if remote {
        FileHandle.standardError.write(Data(
            "⚠️  plumekit \(verb) --remote targets the LIVE D1 \"\(database)\".\n".utf8))
        warnIfNoCloudflareAccount(wranglerToml: wranglerToml)
    }

    // Dump the SQL from the app (build logs → stderr, SQL → captured stdout).
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }
    print("→ plumekit \(verb) \(scope) — dumping \(dumpMode) SQL for \"\(database)\"")
    var dumpArgs = ["run", "--package-path", path, "Server", "--dump-sql", dumpMode]
    if let only { dumpArgs.append(only) }   // seed a single named seeder, not all
    let dump = captureStdout("swift", dumpArgs)
    guard dump.status == 0 else {
        errorLine("dumping \(dumpMode) SQL failed (Server --dump-sql exited \(dump.status))")
        return dump.status
    }

    if let (api, databaseId) = apiTransport {
        guard api.d1Query(databaseId: databaseId, sql: dump.output) != nil else { return 1 }
        return 0
    }

    let sqlFile = bundleDir + "/.plumekit-\(verb).sql"
    guard writeFile(dump.output, to: sqlFile) else {
        errorLine("could not write \(sqlFile)")
        return 1
    }
    defer { try? FileManager.default.removeItem(atPath: sqlFile) }

    var args = (wranglerTool == "npx" ? ["wrangler"] : [])
        + ["d1", "execute", database, scope, "--file", ".plumekit-\(verb).sql"]
    if assumeYes { args.append("--yes") }
    let status = runInherit(wranglerTool, args, cwd: bundleDir, env: wranglerEnv)
    if remote && status != 0 { wranglerFailureHint() }
    return status
}

/// Parse `database_name = "…"` out of a generated wrangler.toml.
private func wranglerDatabaseName(_ tomlPath: String) -> String? {
    guard let toml = try? String(contentsOfFile: tomlPath, encoding: .utf8) else { return nil }
    for rawLine in toml.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("database_name"), let eq = line.firstIndex(of: "=") else { continue }
        return line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return nil
}

func testCommand(path: String, extraArguments: [String] = []) -> Int32 {
    // Compile templates first, like serve/migrate/console — a freshly generated
    // resource references views that don't exist as Swift yet.
    let compiled = compileTemplates(projectPath: path)
    if compiled != 0 { return compiled }
    return runInherit("swift", ["test", "--package-path", path] + extraArguments)
}
