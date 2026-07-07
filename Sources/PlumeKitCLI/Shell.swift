import Foundation

// Tiny process helpers. The CLI is a thin orchestrator over `swift`, `wasm-opt`
// and `wrangler`, so it shells out a lot. Everything goes through `/usr/bin/env`
// so the user's PATH resolves the tool.

/// Merge `extra` over the inherited process environment (extras win). Returns nil when
/// there are no extras, so callers keep the plain inherited environment untouched.
private func mergedEnvironment(_ extra: [String: String]) -> [String: String]? {
    if extra.isEmpty { return nil }
    var env = ProcessInfo.processInfo.environment
    for (key, value) in extra { env[key] = value }
    return env
}

/// Run a tool inheriting stdio; returns its exit status. `env` is merged over the
/// inherited environment (used to spawn wrangler non-interactively).
@discardableResult
func runInherit(_ tool: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let merged = mergedEnvironment(env) { process.environment = merged }
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("plumekit: failed to launch \(tool): \(error)\n".utf8))
        return 127
    }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Run a tool capturing ONLY stdout (stderr is inherited to the terminal). Use
/// when stdout is machine-read — e.g. a `swift run` whose program prints data on
/// stdout while its build logs go to stderr.
func captureStdout(_ tool: String, _ args: [String], cwd: String? = nil,
                   env: [String: String] = [:]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let merged = mergedEnvironment(env) { process.environment = merged }
    let pipe = Pipe()
    process.standardOutput = pipe
    // stderr left inherited → build/progress logs stay visible, uncaptured.
    do {
        try process.run()
    } catch {
        return (127, "")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Run a tool capturing combined stdout+stderr.
func capture(_ tool: String, _ args: [String], cwd: String? = nil,
             env: [String: String] = [:]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let merged = mergedEnvironment(env) { process.environment = merged }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (127, "")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Whether `tool` is resolvable on PATH.
func toolExists(_ tool: String) -> Bool {
    capture("command", ["-v", tool]).status == 0
}

/// The id of the installed Embedded-Swift WebAssembly SDK (e.g.
/// `swift-6.3.2-RELEASE_wasm-embedded`), discovered at runtime so the CLI does
/// not hard-code a toolchain version.
func embeddedWasmSDK() -> String? {
    let (status, output) = capture("swift", ["sdk", "list"])
    guard status == 0 else { return nil }
    for line in output.split(whereSeparator: { $0 == "\n" }) {
        let id = line.trimmingCharacters(in: .whitespaces)
        if id.hasSuffix("_wasm-embedded") { return id }
    }
    return nil
}

/// A static Linux Swift SDK id for cross-building the Lambda binary to Amazon Linux
/// (`provided.al2`). Opt-in via `PLUMEKIT_LINUX_SDK` — auto-detection is deliberately
/// avoided because an installed SDK whose Swift version doesn't match the host
/// toolchain fails the build. Without it the CLI builds with the host toolchain
/// (which runs locally / against LocalStack; a real deploy needs the Linux build).
func staticLinuxSDK() -> String? {
    let override = ProcessInfo.processInfo.environment["PLUMEKIT_LINUX_SDK"]
    return (override?.isEmpty == false) ? override : nil
}

/// Size of a file in bytes, or 0 if it can't be read.
func fileSize(_ path: String) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? Int) ?? 0
}
