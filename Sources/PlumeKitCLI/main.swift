import Foundation

// The single `plumekit` CLI — the framework commands plus the Plume templating
// commands (compile/check/bundle/format/language-server), folded into one binary.
//
// Deliberately dependency-free: arguments are parsed by hand (no ArgumentParser).

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
      plumekit seed [name] [--local|--remote] [path]   Run all seeders (or just <name>): native DB or D1
      plumekit routes [path]                    List the app's registered routes
      plumekit generate <model|controller|ci> … Scaffold code / CI workflows
      plumekit test [path]                      Run the app's test suite
      plumekit doctor                           Check the toolchain for each target
      plumekit mcp                              MCP server (stdio) for AI coding agents
      plumekit build [--target cloudflare|aws|all] [path]  Build the target(s) from
                                                plumekit.toml's [build] (or --target)
      plumekit deploy [--target …] [--skip-migrations|--seed] [path]  Migrate (+seed) + build + deploy
      plumekit secret set <NAME> [path]         Set a deploy secret for the app's target (hidden prompt/stdin)
      plumekit secret list [path]               List the deploy secrets
      plumekit login [provider]                 Store deploy credentials (default: the app's target)
      plumekit logout [provider]                Forget stored credentials

    Templates (Plume):
    \(PlumeTemplateCommands.helpLines)

    `path` defaults to the current directory.
    """)
}

/// Shared parse for `migrate`/`seed`: an optional D1 target (`--local`/`--remote`),
/// an optional `--db NAME` override, `--yes`, and a positional project path.
func parseDBTargetArgs(_ arguments: [String]) -> (path: String, d1: D1Target?, dbName: String?, assumeYes: Bool) {
    var path = "."
    var d1: D1Target?
    var dbName: String?
    var assumeYes = false
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--local": d1 = .local
        case "--remote": d1 = .remote
        case "--db": if index + 1 < arguments.count { dbName = arguments[index + 1]; index += 1 }
        case "--yes", "-y": assumeYes = true
        default: if !arg.hasPrefix("-") { path = arg }
        }
        index += 1
    }
    return (path, d1, dbName, assumeYes)
}

guard let command = arguments.first else {
    printUsage()
    exit(1)
}

switch command {
case "new":
    var name: String?
    var plumekitPath: String?
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--path", index + 1 < arguments.count {
            plumekitPath = arguments[index + 1]; index += 1
        } else if !arg.hasPrefix("-") && name == nil {
            name = arg
        }
        index += 1
    }
    guard let projectName = name else {
        errorLine("usage: plumekit new <name> [--path <plumekit-dir>]")
        exit(1)
    }
    exit(newCommand(name: projectName, plumekitPath: plumekitPath))

case "serve":
    var host = "127.0.0.1"
    var port: UInt16 = 8080
    var path = "."
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--host":
            if index + 1 < arguments.count { host = arguments[index + 1]; index += 1 }
        case "--port":
            if index + 1 < arguments.count, let p = UInt16(arguments[index + 1]) { port = p; index += 1 }
        default:
            if !arg.hasPrefix("-") { path = arg }
        }
        index += 1
    }
    exit(serveCommand(path: path, host: host, port: port))

case "dev":
    var host = "127.0.0.1"
    var port: UInt16 = 8080
    var path = "."
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--host":
            if index + 1 < arguments.count { host = arguments[index + 1]; index += 1 }
        case "--port":
            if index + 1 < arguments.count, let p = UInt16(arguments[index + 1]) { port = p; index += 1 }
        default:
            if !arg.hasPrefix("-") { path = arg }
        }
        index += 1
    }
    exit(devCommand(path: path, host: host, port: port))

case "doctor":
    exit(doctorCommand())

case "secret", "secrets":
    exit(secretCommand(arguments: Array(arguments.dropFirst())))

case "login":
    exit(loginCommand(arguments: Array(arguments.dropFirst())))

case "logout":
    exit(logoutCommand(arguments: Array(arguments.dropFirst())))

case "routes":
    var path = "."
    var index = 1
    while index < arguments.count {
        if !arguments[index].hasPrefix("-") { path = arguments[index] }
        index += 1
    }
    exit(routesCommand(path: path))

case "console":
    var path = "."
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if !arg.hasPrefix("-") { path = arg }
        index += 1
    }
    exit(consoleCommand(path: path))

case "generate", "g":
    exit(generateCommand(arguments: Array(arguments.dropFirst())))

case "migrate":
    let opts = parseDBTargetArgs(arguments)
    exit(migrateCommand(path: opts.path, d1: opts.d1, dbName: opts.dbName, assumeYes: opts.assumeYes))

case "seed":
    let opts = parseDBTargetArgs(arguments)
    // A bare positional that isn't the project directory names a single seeder to run.
    var seedOnly: String?
    if opts.path != "." && !FileManager.default.fileExists(atPath: opts.path + "/plumekit.toml") {
        seedOnly = opts.path
    }
    exit(seedCommand(path: seedOnly != nil ? "." : opts.path, only: seedOnly,
                     d1: opts.d1, dbName: opts.dbName, assumeYes: opts.assumeYes))

case "test":
    var path = "."
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if !arg.hasPrefix("-") { path = arg }
        index += 1
    }
    exit(testCommand(path: path))

case "build":
    var target: String?
    var path = "."
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--target", index + 1 < arguments.count {
            target = arguments[index + 1]; index += 1
        } else if !arg.hasPrefix("-") {
            path = arg
        }
        index += 1
    }
    // Resolve which target(s) to build. `--target` overrides; otherwise read the
    // `[build]` section of plumekit.toml. `--target all` builds every declared target.
    let config = BuildConfig.read(projectPath: path)
    let requested: [String]
    if let target {
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
    var target: String?
    var path = "."
    var skipMigrations = false
    var seedOverride: Bool?
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        if arg == "--target", index + 1 < arguments.count {
            target = arguments[index + 1]; index += 1
        } else if arg == "--skip-migrations" {
            skipMigrations = true
        } else if arg == "--seed" {
            seedOverride = true
        } else if arg == "--skip-seed" {
            seedOverride = false
        } else if !arg.hasPrefix("-") {
            path = arg
        }
        index += 1
    }
    // Migrate → seed → build → deploy, for the target(s) from `--target` or
    // plumekit.toml's [build]. [deploy] migrate/seed set the defaults; --skip-migrations
    // and --seed / --skip-seed override them.
    let deployConfig = BuildConfig.read(projectPath: path)
    let deployTargets: [String]
    if let target {
        deployTargets = (target == "all") ? deployConfig.targets : [target]
    } else {
        deployTargets = deployConfig.resolvedTargets
    }
    guard !deployTargets.isEmpty else {
        errorLine("no deploy target. Pass `--target <cloudflare|aws|native>`, or set")
        errorLine("[build] default / targets in plumekit.toml.")
        exit(1)
    }
    let runMigrate = deployConfig.deployMigrate && !skipMigrations
    let runSeed = seedOverride ?? deployConfig.deploySeed
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
