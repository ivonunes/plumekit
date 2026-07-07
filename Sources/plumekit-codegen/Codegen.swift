import Foundation

// The codegen tool invoked by the PlumeKitCodegen SwiftPM build-tool plugin (and
// usable standalone). Reads plumekit.toml and emits ONE generated file:
//   • composition → Composition.swift   (native adapter wiring, PlumeServer)
//   • bindings    → Bindings.swift       (typed capability gate, App module)
//
// Usage: plumekit-codegen <manifest.toml> <output-dir> <composition|bindings>
//
// Pure TOML→Swift (no Plume, no platform types), so it runs cleanly inside the
// build-tool plugin sandbox. Plume template compilation stays in the `plumekit` CLI.
@main
struct Codegen {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else {
            fail("usage: plumekit-codegen <manifest.toml> <output-dir> <composition|bindings>")
        }
        let manifestPath = arguments[1]
        let outputDir = arguments[2]
        let kind = arguments[3]

        // Parse the (tiny, well-formed) plumekit.toml subset we care about. A missing
        // manifest is fine — we fall back to defaults so the project still builds.
        var native: [String: String] = [:]
        var capabilities: [String: String] = [:]
        var i18n: [String: String] = [:]
        if let toml = try? String(contentsOfFile: manifestPath, encoding: .utf8) {
            var section = ""
            for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    section = String(line.dropFirst().dropLast()); continue
                }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var valuePart = String(line[line.index(after: eq)...])
                if let hash = valuePart.firstIndex(of: "#") { valuePart = String(valuePart[..<hash]) }
                let value = valuePart
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch section {
                case "targets.native": native[key] = value
                case "capabilities": capabilities[key] = value
                case "i18n": i18n[key] = value
                default: break   // [targets.cloudflare]/[targets.aws]/[build] aren't read here
                }
            }
        }

        // A capability is present if declared `true` (or if no [capabilities] table
        // exists at all — back-compat). Presence is the compile-time gate.
        func present(_ name: String) -> Bool {
            capabilities.isEmpty ? true : (capabilities[name] == "true")
        }

        switch kind {
        case "bindings":
            write(bindings(present: present), named: "Bindings.swift", in: outputDir)
            let root = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path
            write(dataRegistry(projectRoot: root, defaultLocale: i18n["default"] ?? "en"),
                  named: "PlumeKitData.swift", in: outputDir)
        case "composition":
            write(composition(native: native, present: present), named: "Composition.swift", in: outputDir)
        case "aws-composition":
            write(awsComposition(present: present), named: "Composition.swift", in: outputDir)
        case "docs-embed":
            // For this kind arg[1] (the manifest slot) is the docs/ directory to embed.
            write(docsEmbedded(docsDir: manifestPath), named: "DocsEmbedded.swift", in: outputDir)
        case "runtime-embed":
            // arg[1] is the runtime/cloudflare/ directory (worker.mjs + wrangler template).
            write(runtimeEmbedded(runtimeDir: manifestPath), named: "CloudflareRuntimeEmbedded.swift", in: outputDir)
        default:
            fail("unknown kind '\(kind)' (have: composition, aws-composition, bindings, docs-embed, runtime-embed)")
        }
    }

    // MARK: - Docs embedding

    /// Embed every `docs/**/*.md` as a raw-string literal so `plumekit mcp`'s search_docs
    /// works from a checkout-less install. Generated at build time by the PlumeEmbed
    /// plugin — `docs/` is the single source of truth, never a checked-in file. Ports
    /// (and replaces) the former embed-docs.py; the byte layout of the `files` array matches.
    static func docsEmbedded(docsDir: String) -> String {
        let fm = FileManager.default
        let subpaths = (try? fm.subpathsOfDirectory(atPath: docsDir)) ?? []
        // Sorted by relative path so the order is deterministic and matches liveDocs().
        let markdown = subpaths.filter { $0.hasSuffix(".md") }.sorted()
        var entries: [String] = []
        for rel in markdown {
            let full = docsDir + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                  let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            entries.append("        (\"\(rel)\", \(rawLiteral(text))),")
        }
        // Built by concatenation (not a Swift multiline literal) so the emitted raw-string
        // delimiters land in the exact columns the content requires.
        var out = ""
        out += "// Generated at build time by the PlumeEmbed plugin. Do not edit.\n"
        out += "// Source of truth: docs/.\n"
        out += "\n"
        out += "// The framework docs, embedded so `plumekit mcp`'s search_docs works without a\n"
        out += "// framework checkout (a brew/tarball install of the CLI). The live docs/ tree is\n"
        out += "// preferred when a checkout is locatable (fresh during framework development).\n"
        out += "enum DocsEmbedded {\n"
        out += "    static let files: [(name: String, content: String)] = [\n"
        out += entries.joined(separator: "\n")
        out += "\n    ]\n"
        out += "}\n"
        return out
    }

    /// Embed the Cloudflare runtime (worker.mjs + wrangler.toml.template) so `plumekit
    /// build --target cloudflare` works from a checkout-less install. Generated at build
    /// time by the PlumeEmbed plugin — `runtime/cloudflare/` is the single source of truth.
    /// Ports (and replaces) the former embed-cloudflare-runtime.py; the `enum` body matches.
    static func runtimeEmbedded(runtimeDir: String) -> String {
        let worker = (try? String(contentsOfFile: runtimeDir + "/worker.mjs", encoding: .utf8)) ?? ""
        let wrangler = (try? String(contentsOfFile: runtimeDir + "/wrangler.toml.template", encoding: .utf8)) ?? ""
        var out = ""
        out += "// Generated at build time by the PlumeEmbed plugin. Do not edit.\n"
        out += "// Source of truth: runtime/cloudflare/.\n"
        out += "\n"
        out += "enum CloudflareRuntimeEmbedded {\n"
        out += "    /// The module-worker entry (JSPI host bindings) `plumekit build --target\n"
        out += "    /// cloudflare` writes as worker.mjs.\n"
        out += "    static let workerJS = " + rawLiteral(worker) + "\n"
        out += "\n"
        out += "    /// The wrangler.toml template written to a project on its first build\n"
        out += "    /// (with __NAME__ substituted).\n"
        out += "    static let wranglerTemplate = " + rawLiteral(wrangler) + "\n"
        out += "}\n"
        return out
    }

    /// Wrap `text` in a Swift raw multiline literal padded with enough `#`s that the
    /// content can neither close the delimiter (`"""#`) nor open interpolation (`\#`).
    static func rawLiteral(_ text: String) -> String {
        var hashes = "#"
        while text.contains("\"\"\"" + hashes) || text.contains("\\" + hashes) {
            hashes += "#"
        }
        return hashes + "\"\"\"\n" + text + "\n\"\"\"" + hashes
    }

    static let capTypes: [(name: String, type: String, field: String)] = [
        ("kv", "KV", "kv"), ("database", "Database", "database"), ("storage", "Storage", "storage"),
        ("cache", "Cache", "cache"),
        ("queue", "Queue", "queue"), ("http", "HTTP", "http"), ("secrets", "Secrets", "secrets"),
        ("mailer", "Mailer", "mailer"),
    ]

    static func bindings(present: (String) -> Bool) -> String {
        let accessors = capTypes.filter { present($0.name) }
            .map { "    public var \($0.name): \($0.type) { context.\($0.field)! }" }
            .joined(separator: "\n")
        return """
        // Generated from plumekit.toml by the PlumeKitCodegen plugin — do not edit.
        // Compile-time-checked access to declared capabilities. Using a capability not
        // declared in plumekit.toml's [capabilities] is a build error (no accessor).
        import PlumeCore

        public struct Bindings {
            let context: Context
            init(_ context: Context) { self.context = context }
        \(accessors)
        }

        extension Request {
            /// Typed, non-optional access to this app's declared capabilities.
            public var bindings: Bindings { Bindings(context) }
        }

        """
    }

    static func composition(native: [String: String], present: (String) -> Bool) -> String {
        var imports: Set<String> = []
        var letLines: [String] = []
        var contextArgs: [String] = []

        if present("kv") {
            letLines.append(#"let kv = NativeDrivers.fileKV(directory: stateDirectory + "/kv")"#)
            contextArgs.append("kv: kv")
        }
        if present("database") {
            let driver = native["database"] ?? "sqlite"
            switch driver {
            case "sqlite":
                letLines.append(#"let database = try NativeDrivers.sqlite(path: stateDirectory + "/app.db")"#)
            case "postgres":
                imports.formUnion(["Foundation", "PlumePostgres"])
                letLines.append(#"let database = try PostgresDriver.connect(url: ProcessInfo.processInfo.environment["DATABASE_URL"] ?? "host=127.0.0.1 port=5432 dbname=app")"#)
            default:
                fail("unknown native database driver '\(driver)' (have: sqlite, postgres)")
            }
            contextArgs.append("database: database")
        }
        if present("storage") {
            let driver = native["storage"] ?? "filesystem"
            switch driver {
            case "filesystem":
                letLines.append(#"let storage = NativeDrivers.filesystemStorage(directory: stateDirectory + "/storage")"#)
            case "memory":
                letLines.append("let storage = NativeDrivers.memoryStorage()")
            case "s3":
                imports.formUnion(["Foundation", "PlumeS3"])
                letLines.append(#"""
                let s3env = ProcessInfo.processInfo.environment
                        let storage = S3Driver.connect(
                            endpoint: s3env["S3_ENDPOINT"] ?? "http://127.0.0.1:9000",
                            region: s3env["S3_REGION"] ?? "us-east-1",
                            bucket: s3env["S3_BUCKET"] ?? "plumekit-storage",
                            accessKey: s3env["S3_ACCESS_KEY"] ?? "",
                            secretKey: s3env["S3_SECRET_KEY"] ?? "")
                """#)
            default:
                fail("unknown native storage driver '\(driver)' (have: filesystem, memory, s3)")
            }
            contextArgs.append("storage: storage")
        }
        if present("cache") {
            letLines.append("let cache = NativeDrivers.memoryCache()")
            contextArgs.append("cache: cache")
        }
        if present("queue") {
            letLines.append("let queue = NativeDrivers.inProcessQueue()")
            contextArgs.append("queue: queue")
        }
        if present("http") {
            letLines.append("let http = NativeDrivers.httpClient()")
            contextArgs.append("http: http")
        }
        if present("secrets") {
            letLines.append("let secrets = NativeDrivers.envSecrets()")
            contextArgs.append("secrets: secrets")
        }
        if present("mailer") {
            let driver = native["mailer"] ?? "log"
            switch driver {
            case "log":
                letLines.append("let mailer = NativeDrivers.logMailer()")
            case "smtp":
                letLines.append("let mailer = NativeDrivers.smtpMailer()")
            default:
                fail("unknown native mailer driver '\(driver)' (have: log, smtp)")
            }
            contextArgs.append("mailer: mailer")
        }
        contextArgs.append("log: NativeDrivers.stdoutLog")

        let extraImports = imports.sorted().map { "import \($0)" }.joined(separator: "\n")
        let body = letLines.map { "        \($0)" }.joined(separator: "\n")
        return """
        // Generated from plumekit.toml by the PlumeKitCodegen plugin — do not edit.
        import PlumeCore
        import PlumeServer
        \(extraImports)

        enum Composition {
            static func nativeContext(stateDirectory: String) throws -> Context {
        \(body)
                return Context(\(contextArgs.joined(separator: ", ")))
            }
        }

        """
    }

    // The AWS composition root — wires the AWS adapter set behind the same
    // capabilities. Config comes from the environment; `AWS_ENDPOINT_URL` overrides
    // every service endpoint (set it to http://localhost:4566 for LocalStack).
    static func awsComposition(present: (String) -> Bool) -> String {
        var imports: Set<String> = []
        var letLines: [String] = []
        var contextArgs: [String] = []

        if present("kv") {
            letLines.append(#"let kv = DynamoKVDriver.connect(table: env["KV_TABLE"] ?? "app_kv", region: region, accessKey: accessKey, secretKey: secretKey, endpoint: awsEndpoint)"#)
            contextArgs.append("kv: kv")
        }
        if present("database") {
            imports.insert("PlumePostgres")
            letLines.append(#"let database = try PostgresDriver.connect(url: env["DATABASE_URL"] ?? "")"#)
            contextArgs.append("database: database")
        }
        if present("storage") {
            imports.insert("PlumeS3")
            letLines.append(#"let s3Endpoint = env["S3_ENDPOINT"] ?? awsEndpoint ?? "https://s3.\(region).amazonaws.com""#)
            letLines.append(#"let storage = S3Driver.connect(endpoint: s3Endpoint, region: region, bucket: env["S3_BUCKET"] ?? "app-storage", accessKey: accessKey, secretKey: secretKey)"#)
            contextArgs.append("storage: storage")
        }
        if present("cache") {
            letLines.append(#"let cache = DynamoCacheDriver.connect(table: env["CACHE_TABLE"] ?? "app_cache", region: region, accessKey: accessKey, secretKey: secretKey, endpoint: awsEndpoint)"#)
            contextArgs.append("cache: cache")
        }
        if present("queue") {
            letLines.append(#"let queue = SQSDriver.connect(queueURL: env["SQS_URL"] ?? "", region: region, accessKey: accessKey, secretKey: secretKey)"#)
            contextArgs.append("queue: queue")
        }
        if present("http") {
            letLines.append("let http = AWSHTTPDriver.connect()")
            contextArgs.append("http: http")
        }
        if present("secrets") {
            letLines.append("let secrets = SSMDriver.connect(region: region, accessKey: accessKey, secretKey: secretKey, endpoint: awsEndpoint)")
            contextArgs.append("secrets: secrets")
        }
        if present("mailer") {
            letLines.append("let mailer = SESDriver.connect(region: region, accessKey: accessKey, secretKey: secretKey, endpoint: awsEndpoint)")
            contextArgs.append("mailer: mailer")
        }
        contextArgs.append("log: { print($0) }")

        let extraImports = imports.sorted().map { "import \($0)" }.joined(separator: "\n")
        let body = letLines.map { "        \($0)" }.joined(separator: "\n")
        return """
        // Generated from plumekit.toml by the PlumeKitCodegen plugin — do not edit.
        import PlumeCore
        import PlumeAWS
        import Foundation
        \(extraImports)

        enum Composition {
            static func awsContext() throws -> Context {
                let env = ProcessInfo.processInfo.environment
                let region = env["AWS_REGION"] ?? "us-east-1"
                let accessKey = env["AWS_ACCESS_KEY_ID"] ?? ""
                let secretKey = env["AWS_SECRET_ACCESS_KEY"] ?? ""
                let awsEndpoint = env["AWS_ENDPOINT_URL"]
        \(body)
                return Context(\(contextArgs.joined(separator: ", ")))
            }
        }

        """
    }

    // MARK: - Translations discovery

    /// Compile `Translations/<locale>.json` (flat `{"key": "value"}` files) into a
    /// `plumeKitTranslations` value. The default locale comes from `[i18n] default`.
    static func translationsLiteral(projectRoot: String, defaultLocale: String) -> String {
        let dir = projectRoot + "/Translations"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var tables: [String] = []
        for file in files.sorted() where file.hasSuffix(".json") {
            let locale = String(file.dropLast(".json".count))
            guard let data = FileManager.default.contents(atPath: dir + "/" + file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileHandle.standardError.write(Data("plumekit-codegen: \(file) is not a flat JSON object — skipped.\n".utf8))
                continue
            }
            var entries: [String] = []
            for key in object.keys.sorted() {
                guard let value = object[key] as? String else {
                    FileHandle.standardError.write(Data("plumekit-codegen: \(file) key \"\(key)\" is not a string — skipped.\n".utf8))
                    continue
                }
                entries.append("\"\(swiftEscape(key))\": \"\(swiftEscape(value))\"")
            }
            tables.append("\"\(swiftEscape(locale))\": [\(entries.joined(separator: ", "))]")
        }
        let dict = tables.isEmpty ? "[:]" : "[\n    " + tables.joined(separator: ",\n    ") + ",\n]"
        return "public let plumeKitTranslations = Translations(default: \"\(swiftEscape(defaultLocale))\", \(dict))"
    }

    static func swiftEscape(_ string: String) -> String {
        var out = ""
        for character in string {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Migration / seeder discovery

    /// Collect the migrations and seeders declared in Sources/App/Database/, in
    /// filename order, into `plumeKitMigrations` / `plumeKitSeeders`. This is how a
    /// dropped-in migration/seeder file runs automatically: Swift can't enumerate them
    /// at runtime, so the build discovers them and generates the lists.
    static func dataRegistry(projectRoot: String, defaultLocale: String) -> String {
        let appRoot = projectRoot + "/Sources/App"
        let base = appRoot + "/Database/"
        let migrations = scanBindings(dir: base + "Migrations", declaring: "Migration")
        let seeders = scanBindings(dir: base + "Seeders", declaring: "Seeder")

        let migrationList = migrations.map { $0.binding }.joined(separator: ", ")
        let seederList = seeders.map { "(name: \"\($0.name)\", seeder: \($0.binding))" }.joined(separator: ", ")

        return """
        // Generated. Do not edit. Migrations and seeders found in Sources/App/Database/,
        // jobs in Sources/App/Jobs/, translations in Translations/ — drop a file in and
        // it's picked up on the next build.
        import PlumeCore
        import PlumeORM

        public let plumeKitMigrations: [Migration] = [\(migrationList)]
        public let plumeKitSeeders: [(name: String, seeder: Seeder)] = [\(seederList)]
        \(translationsLiteral(projectRoot: projectRoot, defaultLocale: defaultLocale))
        \(jobsRegistry(appRoot: appRoot))
        """
    }

    /// Auto-register every `Job` under `Sources/App/Jobs/` (recursively — organize into
    /// subfolders freely; order is irrelevant since jobs dispatch by name) and wire the
    /// manually-declared schedule's tick in as a job. `buildSchedule()` calls the user's
    /// `registerSchedules(_:)` in `Sources/App/Schedules.swift`.
    static func jobsRegistry(appRoot: String) -> String {
        let jobs = scanJobs(dir: appRoot + "/Jobs")
        // De-dup type names (a type plus an `extension X: Job` both match — register once).
        var seenTypes: Set<String> = []
        let unique = jobs.filter { seenTypes.insert($0.type).inserted }
        // Fail on two DIFFERENT jobs sharing a dispatch name (`static var name`) — dispatch
        // matches by name, so one would be silently shadowed. (Duplicate Swift TYPE names are
        // already a compiler error, so that is not what we guard here.)
        var byDispatchName: [String: String] = [:]
        for job in unique {
            guard let name = job.name else { continue }
            if let other = byDispatchName[name] {
                fail("jobs \(other) and \(job.type) both dispatch as \"\(name)\" — one would be silently shadowed. Give each a unique `static var name`.")
            }
            byDispatchName[name] = job.type
        }
        let registrations = unique.map { "        registry.register(\($0.type).self)" }.joined(separator: "\n")
        // Schedules.swift is optional: only call registerSchedules(_:) when the app declares it,
        // else generate an empty schedule (avoids an opaque "cannot find registerSchedules").
        let buildScheduleBody = appDeclaresRegisterSchedules(appRoot: appRoot)
            ? "    var schedule = Schedule()\n    registerSchedules(&schedule)\n    return schedule"
            : "    // no registerSchedules(_:) declared — add Sources/App/Schedules.swift for scheduled tasks\n    return Schedule()"
        return """
        public func buildSchedule() -> Schedule {
        \(buildScheduleBody)
        }

        public func buildJobs() -> JobRegistry {
            var registry = JobRegistry()
        \(registrations)
            registry.include(buildSchedule())   // the schedule's tick is delivered as a job
            return registry
        }
        """
    }

    /// Every type conforming to `Job` under `dir` (recursively), with its dispatch name
    /// (`static var name`) when the file holds exactly one job. Sorted by type for a
    /// deterministic build. Text scan (keeps the codegen tool dependency-free): matches a
    /// `struct`/`class`/`enum`/`actor`/`extension` whose inheritance clause contains `Job`
    /// as a whole word. Line comments are stripped first so a commented-out declaration is
    /// ignored.
    static func scanJobs(dir: String) -> [(type: String, name: String?)] {
        guard let enumerator = FileManager.default.enumerator(atPath: dir) else { return [] }
        var jobs: [(type: String, name: String?)] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            guard let raw = try? String(contentsOfFile: dir + "/" + path, encoding: .utf8) else { continue }
            let source = stripComments(raw)
            let types = jobTypeNames(in: source)
            if types.isEmpty {
                FileHandle.standardError.write(Data(
                    "plumekit-codegen: \(path) declares no `Job` type — skipped.\n".utf8))
                continue
            }
            // Pair each type with its dispatch name (source order) when the file has one
            // `static var name` per type — covers multi-job files, not just one-per-file.
            // If the counts don't line up, leave names nil so the collision check skips this
            // file rather than mis-pairing.
            let dispatchNames = jobDispatchNames(in: source)
            if types.count == dispatchNames.count {
                for (type, name) in zip(types, dispatchNames) { jobs.append((type: type, name: name)) }
            } else {
                jobs.append(contentsOf: types.map { (type: $0, name: nil) })
            }
        }
        return jobs.sorted { $0.type < $1.type }
    }

    /// Strip `//` line comments and `/* … */` block comments (block comments nest, as in
    /// Swift), but NOT a comment marker inside a string literal (which would corrupt a
    /// declaration sharing a line with, e.g., `let u = "http://…"`). Newlines are kept so
    /// line structure — and thus the regexes below — stays intact. So a commented-out
    /// declaration (either comment style) is never mistaken for real code.
    static func stripComments(_ source: String) -> String {
        enum Mode { case code, string, line, block }
        var mode: Mode = .code
        var escaped = false
        var blockDepth = 0
        var out = ""
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch mode {
            case .code:
                if c == "\"" { out.append(c); mode = .string; escaped = false }
                else if c == "/", next == "/" { mode = .line; i += 1 }
                else if c == "/", next == "*" { mode = .block; blockDepth = 1; i += 1 }
                else { out.append(c) }
            case .string:
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { mode = .code }
            case .line:
                if c == "\n" { out.append(c); mode = .code }   // keep the newline, drop the rest
            case .block:
                if c == "/", next == "*" { blockDepth += 1; i += 1 }
                else if c == "*", next == "/" { blockDepth -= 1; i += 1; if blockDepth == 0 { mode = .code } }
                else if c == "\n" { out.append(c) }            // preserve line structure
            }
            i += 1
        }
        return out
    }

    static func jobTypeNames(in source: String) -> [String] {
        // `(struct|final class|class|actor|enum|extension) Name<generics>? : <inheritance> {`
        // `extension` catches a conformance added retroactively (`extension Foo: Job {}`).
        let pattern = #"(?:struct|final\s+class|class|actor|enum|extension)\s+([A-Za-z_][\w.]*)\s*(?:<[^>]*>)?\s*:\s*([^{]*?)(?:\bwhere\b[^{]*)?\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = source as NSString
        var names: [String] = []
        for m in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let inheritance = ns.substring(with: m.range(at: 2))
            if inheritance.range(of: #"\bJob\b"#, options: .regularExpression) != nil {
                names.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return names
    }

    /// Dispatch-name string literals (`static let/var name … "…"`, single line) in `source`.
    static func jobDispatchNames(in source: String) -> [String] {
        let pattern = #"static\s+(?:let|var)\s+name\b[^"\n]*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// True when the app declares `func registerSchedules(_:)` (Sources/App/Schedules.swift).
    static func appDeclaresRegisterSchedules(appRoot: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: appRoot) else { return false }
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            guard let raw = try? String(contentsOfFile: appRoot + "/" + path, encoding: .utf8) else { continue }
            // Strip comments first so a commented-out `func registerSchedules` isn't counted
            // as declared (which would emit a call to a function that doesn't exist).
            if stripComments(raw).range(of: #"func\s+registerSchedules\b"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// The top-level `let <name> = <declaring>(…)` binding in each `.swift` file of
    /// `dir`, in filename order. One binding per file (the convention the generators
    /// follow); comment lines are skipped. `name` is the filename stem, for `seed <name>`.
    static func scanBindings(dir: String, declaring type: String) -> [(name: String, binding: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var found: [(name: String, binding: String)] = []
        for file in files.sorted() where file.hasSuffix(".swift") {
            guard let contents = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { continue }
            var matched = false
            for rawLine in contents.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                if let binding = parseBinding(line, declaring: type) {
                    found.append((name: String(file.dropLast(".swift".count)), binding: binding))
                    matched = true
                    break
                }
            }
            // A file that declares no `let <name> = \(type)(` on a single line would be
            // silently skipped; warn so a mistyped or line-wrapped binding is visible.
            if !matched {
                FileHandle.standardError.write(Data(
                    "plumekit-codegen: \(file) has no `let <name> = \(type)(…)` — skipped.\n".utf8))
            }
        }
        return found
    }

    /// Parse `[public ]let <ident> = <type>` and return `<ident>`, else nil.
    static func parseBinding(_ line: String, declaring type: String) -> String? {
        var s = Substring(line)
        if s.hasPrefix("public ") { s = s.dropFirst("public ".count) }
        guard s.hasPrefix("let ") else { return nil }
        s = s.dropFirst("let ".count)
        guard let sep = s.firstIndex(where: { $0 == " " || $0 == "=" || $0 == ":" }) else { return nil }
        let ident = String(s[..<sep])
        let rest = s[sep...].drop { $0 == " " || $0 == "=" || $0 == ":" }
        guard !ident.isEmpty, rest.hasPrefix(type) else { return nil }
        // Guard against a longer type name (e.g. "MigrationSet") matching "Migration".
        let after = rest.dropFirst(type.count).first
        if let after, !(after == "(" || after == " " || after == "{" || after == ".") { return nil }
        return ident
    }

    static func write(_ contents: String, named file: String, in outputDir: String) {
        let url = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try contents.write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
        } catch {
            fail("could not write \(file): \(error)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("plumekit-codegen: \(message)\n".utf8))
        exit(1)
    }
}
