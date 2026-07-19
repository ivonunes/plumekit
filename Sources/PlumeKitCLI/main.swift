import Foundation

// The single `plumekit` CLI — the framework commands plus the Plume templating
// commands (compile/check/bundle/format/language-server), folded into one binary.
//
// Deliberately dependency-free: arguments are parsed by hand (no ArgumentParser),
// through one strict helper — `--flag value` and `--flag=value` both work, short
// aliases are declared per command, and an unknown flag is an ERROR, not a silent
// no-op (muscle-memory typos like `-p 3000` must never quietly serve on 8080).

let arguments = Array(CommandLine.arguments.dropFirst())

func printUsage() {
    print("""
    plumekit — a Swift web framework that runs anywhere, with the Plume templating language

    App:
      plumekit new <name> [--path <dir>]        Scaffold a new app (interactive)
      plumekit serve [--host H] [--port N] [path] Run the app natively (default :8080)
      plumekit dev [--host H] [--port N] [path] Serve + rebuild/restart on file changes
      plumekit console [path]                   Interactive REPL against the app + native KV
      plumekit migrate [--local|--remote] [path] Apply migrations: native DB, or a Cloudflare D1
      plumekit migrate --rollback [N] [path]    Reverse the last N migrations (native DB)
      plumekit migrate --status [path]          List each migration and whether it has run
      plumekit seed [name] [--local|--remote] [path]   Run all seeders (or just <name>): native DB or D1
      plumekit routes [path]                    List the app's registered routes
      plumekit generate <model|controller|ci> … Scaffold code / CI workflows
      plumekit test [path] [swift-test flags]   Run the app's test suite (extra flags pass through)
      plumekit doctor                           Check the toolchain for each target
      plumekit mcp                              MCP server (stdio) for AI coding agents
      plumekit build [--target cloudflare|aws|all] [path]  Build the target(s) from
                                                plumekit.toml's [build] (or --target)
      plumekit deploy [--target …] [--skip-migrations|--seed] [path]  Migrate (+seed) + build + deploy
      plumekit secret set <NAME> [path]         Set a deploy secret for the app's target (hidden prompt/stdin)
      plumekit secret list [path]               List the deploy secrets
      plumekit token [provider]                 Open the pre-filled deploy-token creation page
      plumekit login [provider]                 Store deploy credentials (default: the app's target)
      plumekit logout [provider]                Forget stored credentials

    Templates (Plume):
    \(PlumeTemplateCommands.helpLines)

    `path` defaults to the current directory.
    """)
}

/// Parsed command line: `--flag value` / `--flag=value` values, boolean flags
/// (canonical names), and bare positionals.
struct ParsedOptions {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
}

/// Strict parse for one command. `valueSpellings`/`boolSpellings` map every
/// accepted spelling (`--port`, `-p`) to its canonical name (`port`). An unknown
/// flag or a value flag without a value prints the error and returns nil; the
/// caller exits 1.
func parseOptions(
    _ arguments: [String],
    command: String,
    valueSpellings: [String: String] = [:],
    boolSpellings: [String: String] = [:]
) -> ParsedOptions? {
    var parsed = ParsedOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("-") {
            var spelling = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                spelling = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            if let canonical = valueSpellings[spelling] {
                if let inlineValue {
                    parsed.values[canonical] = inlineValue
                } else if index + 1 < arguments.count {
                    parsed.values[canonical] = arguments[index + 1]
                    index += 1
                } else {
                    errorLine("plumekit \(command): \(spelling) needs a value")
                    return nil
                }
            } else if let canonical = boolSpellings[spelling], inlineValue == nil {
                parsed.flags.insert(canonical)
            } else {
                errorLine("plumekit \(command): unknown option '\(argument)'")
                errorLine("run `plumekit --help` for usage")
                return nil
            }
        } else {
            parsed.positionals.append(argument)
        }
        index += 1
    }
    return parsed
}

/// The `--host`/`--port` pair `serve` and `dev` share, validated. Exits on a
/// malformed port instead of quietly treating it as the project path.
func parseServeOptions(_ arguments: [String], command: String) -> (host: String, port: UInt16, path: String)? {
    guard let parsed = parseOptions(arguments, command: command,
                                    valueSpellings: ["--host": "host", "-H": "host",
                                                     "--port": "port", "-p": "port"]) else { return nil }
    var port: UInt16 = 8080
    if let raw = parsed.values["port"] {
        guard let value = UInt16(raw), value > 0 else {
            errorLine("plumekit \(command): invalid port '\(raw)'")
            return nil
        }
        port = value
    }
    return (parsed.values["host"] ?? "127.0.0.1", port, parsed.positionals.first ?? ".")
}

guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "new":
    guard let parsed = parseOptions(Array(arguments.dropFirst()), command: "new",
                                    valueSpellings: ["--path": "path"]) else { exit(1) }
    guard let projectName = parsed.positionals.first else {
        errorLine("usage: plumekit new <name> [--path <plumekit-dir>]")
        exit(1)
    }
    exit(newCommand(name: projectName, plumekitPath: parsed.values["path"]))

case "serve":
    guard let options = parseServeOptions(Array(arguments.dropFirst()), command: "serve") else { exit(1) }
    exit(serveCommand(path: options.path, host: options.host, port: options.port))

case "dev":
    guard let options = parseServeOptions(Array(arguments.dropFirst()), command: "dev") else { exit(1) }
    exit(devCommand(path: options.path, host: options.host, port: options.port))

case "doctor":
    exit(doctorCommand())

case "secret", "secrets":
    exit(secretCommand(arguments: Array(arguments.dropFirst())))

case "token":
    exit(tokenCommand(arguments: Array(arguments.dropFirst())))

case "login":
    exit(loginCommand(arguments: Array(arguments.dropFirst())))

case "logout":
    exit(logoutCommand(arguments: Array(arguments.dropFirst())))

case "routes":
    guard let parsed = parseOptions(Array(arguments.dropFirst()), command: "routes") else { exit(1) }
    exit(routesCommand(path: parsed.positionals.first ?? "."))

case "console":
    guard let parsed = parseOptions(Array(arguments.dropFirst()), command: "console") else { exit(1) }
    exit(consoleCommand(path: parsed.positionals.first ?? "."))

case "generate", "g":
    exit(generateCommand(arguments: Array(arguments.dropFirst())))

case "migrate":
    guard let parsed = parseOptions(
        Array(arguments.dropFirst()), command: "migrate",
        valueSpellings: ["--db": "db"],
        boolSpellings: ["--local": "local", "--remote": "remote", "--yes": "yes", "-y": "yes",
                        "--status": "status", "--rollback": "rollback"]) else { exit(1) }
    let d1: D1Target? = parsed.flags.contains("local") ? .local
        : (parsed.flags.contains("remote") ? .remote : nil)
    var path = "."
    var rollbackSteps: Int? = nil
    var positionals = parsed.positionals
    if parsed.flags.contains("rollback") {
        // `--rollback 2` — a leading integer positional is the step count.
        rollbackSteps = 1
        if let first = positionals.first, let steps = Int(first), steps > 0 {
            rollbackSteps = steps
            positionals.removeFirst()
        }
    }
    if let remaining = positionals.first { path = remaining }
    if parsed.flags.contains("status") {
        exit(migrateStatusCommand(path: path, d1: d1))
    }
    if let rollbackSteps {
        exit(migrateRollbackCommand(path: path, steps: rollbackSteps, d1: d1))
    }
    exit(migrateCommand(path: path, d1: d1, dbName: parsed.values["db"],
                        assumeYes: parsed.flags.contains("yes")))

case "seed":
    guard let parsed = parseOptions(
        Array(arguments.dropFirst()), command: "seed",
        valueSpellings: ["--db": "db"],
        boolSpellings: ["--local": "local", "--remote": "remote", "--yes": "yes", "-y": "yes"]) else { exit(1) }
    let d1: D1Target? = parsed.flags.contains("local") ? .local
        : (parsed.flags.contains("remote") ? .remote : nil)
    // A bare positional that isn't the project directory names a single seeder to run.
    var path = "."
    var seedOnly: String?
    for positional in parsed.positionals {
        if FileManager.default.fileExists(atPath: positional + "/plumekit.toml") {
            path = positional
        } else {
            seedOnly = positional
        }
    }
    exit(seedCommand(path: path, only: seedOnly, d1: d1, dbName: parsed.values["db"],
                     assumeYes: parsed.flags.contains("yes")))

case "test":
    // Only the leading positional is ours (the project path); everything else —
    // `--filter Foo`, `--parallel`, … — passes through to `swift test` untouched.
    // A leading bare word that is NOT a package is almost certainly a mistyped
    // path — diagnose it rather than silently testing the current directory.
    let rest = Array(arguments.dropFirst())
    var path = "."
    var passthrough = rest
    if let first = rest.first, !first.hasPrefix("-") {
        guard FileManager.default.fileExists(atPath: first + "/Package.swift") else {
            errorLine("plumekit test: no Package.swift at '\(first)'")
            exit(1)
        }
        path = first
        passthrough = Array(rest.dropFirst())
    }
    exit(testCommand(path: path, extraArguments: passthrough))

case "build":
    guard let parsed = parseOptions(Array(arguments.dropFirst()), command: "build",
                                    valueSpellings: ["--target": "target"]) else { exit(1) }
    let path = parsed.positionals.first ?? "."
    // Resolve which target(s) to build. `--target` overrides; otherwise read the
    // `[build]` section of plumekit.toml. `--target all` builds every declared target.
    let config = BuildConfig.read(projectPath: path)
    let requested: [String]
    if let target = parsed.values["target"] {
        requested = (target == "all") ? config.targets : [target]
    } else {
        requested = config.resolvedTargets
    }
    guard !requested.isEmpty else {
        errorLine("no build target. Pass `--target <cloudflare|aws>`, or set")
        errorLine("[build] default / targets in plumekit.toml.")
        exit(1)
    }

    for buildTarget in requested {
        let status: Int32
        switch buildTarget {
        case "cloudflare": status = buildCloudflareCommand(path: path, outDir: config.out)
        case "aws":        status = buildAWSCommand(path: path, outDir: config.out)
        case "native":     status = buildNativeCommand(path: path)
        default:
            errorLine("unknown build target '\(buildTarget)'. Supported: cloudflare, aws, native"); status = 1
        }
        if status != 0 { exit(status) }
    }
    exit(0)

case "deploy":
    guard let parsed = parseOptions(
        Array(arguments.dropFirst()), command: "deploy",
        valueSpellings: ["--target": "target"],
        boolSpellings: ["--skip-migrations": "skip-migrations", "--seed": "seed",
                        "--skip-seed": "skip-seed"]) else { exit(1) }
    let path = parsed.positionals.first ?? "."
    // Migrate → seed → build → deploy, for the target(s) from `--target` or
    // plumekit.toml's [build]. [deploy] migrate/seed set the defaults; --skip-migrations
    // and --seed / --skip-seed override them.
    let deployConfig = BuildConfig.read(projectPath: path)
    let deployTargets: [String]
    if let target = parsed.values["target"] {
        deployTargets = (target == "all") ? deployConfig.targets : [target]
    } else {
        deployTargets = deployConfig.resolvedTargets
    }
    guard !deployTargets.isEmpty else {
        errorLine("no deploy target. Pass `--target <cloudflare|aws|native>`, or set")
        errorLine("[build] default / targets in plumekit.toml.")
        exit(1)
    }
    let runMigrate = deployConfig.deployMigrate && !parsed.flags.contains("skip-migrations")
    let runSeed = parsed.flags.contains("seed") ? true
        : (parsed.flags.contains("skip-seed") ? false : deployConfig.deploySeed)
    for deployTarget in deployTargets {
        let status = deployCommand(target: deployTarget, path: path, outDir: deployConfig.out,
                                   migrate: runMigrate, seed: runSeed)
        if status != 0 { exit(status) }
    }
    exit(0)

case "mcp":
    exit(MCPServer.run())

case "compile", "check", "bundle", "format", "language-server", "version", "--version":
    exit(PlumeTemplateCommands.run(command, options: Array(arguments.dropFirst())))

case "-h", "--help", "help":
    printUsage()
    exit(0)

default:
    errorLine("unknown command '\(command)'")
    printUsage()
    exit(1)
}
