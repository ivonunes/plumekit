#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import App
import PlumeCore
import PlumeServer

// Native entry point for `plumekit serve` (and `plumekit console` via --console).
// The request Context is built by the GENERATED composition root (from
// plumekit.toml) — swapping a driver there relinks the adapter set with no change
// here. Accepts --host, --port, --state-dir, --console.
var host = "127.0.0.1"
var port: UInt16 = 8080
var stateDir = ".plumekit"
var consoleMode = false
var migrateMode = false
var rollbackSteps: Int?
var statusMode = false

let arguments = CommandLine.arguments

// `--routes`: print the app's registered routes and exit (bindings not needed).
if arguments.contains("--routes") {
    for route in buildApp().routeList { print("\(route.method)\t\(route.path)") }
    exit(0)
}

var i = 1
while i < arguments.count {
    switch arguments[i] {
    case "--port":
        if i + 1 < arguments.count, let p = UInt16(arguments[i + 1]) { port = p; i += 1 }
    case "--host":
        if i + 1 < arguments.count { host = arguments[i + 1]; i += 1 }
    case "--state-dir":
        if i + 1 < arguments.count { stateDir = arguments[i + 1]; i += 1 }
    case "--console":
        consoleMode = true
    case "--migrate":
        migrateMode = true
    case "--rollback":
        rollbackSteps = 1
        if i + 1 < arguments.count, let n = Int(arguments[i + 1]), n > 0 { rollbackSteps = n; i += 1 }
    case "--migration-status":
        statusMode = true
    default:
        break
    }
    i += 1
}

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

let context: Context
do {
    context = try Composition.nativeContext(stateDirectory: stateDir)
} catch {
    print("plumekit: failed to build native context: \(error)")
    exit(1)
}

if migrateMode {
    NativeDrivers.installNativeClock()
    guard let database = context.database else {
        print("plumekit migrate: no database driver configured in plumekit.toml")
        exit(1)
    }
    do {
        let applied = try await runMigrations(in: database)
        if applied.isEmpty {
            print("plumekit migrate: schema up to date (no changes)")
        } else {
            print("plumekit migrate: applied \(applied.count) change(s):")
            for version in applied { print("  + \(version)") }
        }
    } catch {
        print("plumekit migrate: \(error)")
        exit(1)
    }
} else if let rollbackSteps {
    NativeDrivers.installNativeClock()
    guard let database = context.database else {
        print("plumekit migrate: no database driver configured in plumekit.toml")
        exit(1)
    }
    do {
        let reverted = try await appMigrator().rollback(in: database, steps: rollbackSteps)
        print(reverted.isEmpty ? "plumekit migrate: nothing to roll back" : "plumekit migrate: rolled back \(reverted.count) change(s)")
        for version in reverted { print("  - \(version)") }
    } catch {
        print("plumekit migrate: \(error)")
        exit(1)
    }
} else if statusMode {
    NativeDrivers.installNativeClock()
    guard let database = context.database else {
        print("plumekit migrate: no database driver configured in plumekit.toml")
        exit(1)
    }
    do {
        for entry in try await appMigrator().status(in: database) {
            print("  \(entry.applied ? "up  " : "down")  \(entry.version)")
        }
    } catch {
        print("plumekit migrate: \(error)")
        exit(1)
    }
} else if consoleMode {
    await PlumeServer.console(buildApp(), context: context)
} else {
    do {
        let channels = ChannelHub(stateDirectory: stateDir + "/channels") { message, context in
            try await buildChannel().onMessage(message, context)   // same Channel as the DO
        }
        // A Broadcaster that originates broadcasts into the in-process hub, on
        // the context jobs + request handlers share — so a model change/job can fan
        // out with no request in scope.
        let broadcaster = Broadcaster { channel, pushes in
            await channels.broadcast(channel.value, pushes)
        }
        let serveContext = context.adding(broadcaster: broadcaster)
        try await PlumeServer.run(buildApp(), host: host, port: port, context: serveContext,
                                   jobs: buildJobs(), channels: channels)
    } catch {
        print("plumekit serve: \(error)")
        exit(1)
    }
}
