//
//  RenderHarness.swift
//  PlumeTests — compiling back-end
//
//  Builds and runs generated Swift end-to-end so tests can assert the actual
//  rendered bytes. The SAME generated code is exercised two ways:
//
//    * .native        — built with the host toolchain and run directly.
//    * .embeddedWasm  — built with the Embedded-Swift Wasm SDK and run under
//                       Node's WASI. This is the link-and-run gate that catches
//                       Embedded-only failures a library-only build would hide.
//
//  Each case's render function is invoked into a fresh `HTML` buffer; the buffers
//  are length-prefix framed to stdout so arbitrary bytes survive the round trip.
//

import Foundation
import Plume

struct RenderCase {
    /// Unique key used to retrieve this case's bytes from the result.
    var name: String
    /// The `.plume` source to compile.
    var template: String
    /// A Swift statement that renders into a local `var out: HTML`,
    /// e.g. `greeting(name: "Ann", into: &out)`.
    var call: String
}

enum RenderTarget {
    case native
    case embeddedWasm
}

enum RenderHarnessError: Error, CustomStringConvertible {
    case toolchainUnavailable(String)
    case buildFailed(String)
    case runFailed(String)

    var description: String {
        switch self {
        case .toolchainUnavailable(let message): return "toolchain unavailable: \(message)"
        case .buildFailed(let message): return "build failed:\n\(message)"
        case .runFailed(let message): return "run failed:\n\(message)"
        }
    }
}

enum RenderHarness {
    static let embeddedSDK = ProcessInfo.processInfo.environment["PLUME_WASM_SDK"]
        ?? "swift-6.3.2-RELEASE_wasm-embedded"

    /// Compiles `cases` (sharing `fixtures` model types) and returns each case's
    /// rendered bytes keyed by name.
    static func render(
        cases: [RenderCase],
        fixtures: String,
        target: RenderTarget,
        options: PlumeSwiftOptions = PlumeSwiftOptions(emitSourceLocations: false)
    ) throws -> [String: [UInt8]] {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources/app")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        try packageManifest(target: target).write(
            to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try fixtures.write(
            to: sources.appendingPathComponent("Fixtures.swift"), atomically: true, encoding: .utf8)

        // A template may be rendered by several cases (same component, different
        // inputs), so generate each distinct template exactly once to avoid
        // duplicate function definitions. All templates see each other's
        // components so cross-template calls lower to typed function calls.
        var uniqueTemplates: [String] = []
        var seen = Set<String>()
        for renderCase in cases where seen.insert(renderCase.template).inserted {
            uniqueTemplates.append(renderCase.template)
        }
        let componentSources = Dictionary(
            uniqueKeysWithValues: uniqueTemplates.enumerated().map {
                ("case\($0.offset).plume", $0.element)
            })
        for (index, template) in uniqueTemplates.enumerated() {
            let swift = try PlumeSwiftBackend.generate(
                source: template,
                sourceName: "case\(index).plume",
                componentSources: componentSources,
                options: options)
            try swift.write(
                to: sources.appendingPathComponent("Views_\(index).swift"),
                atomically: true, encoding: .utf8)
        }

        try mainSource(cases: cases).write(
            to: sources.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)

        let stdout: Data
        switch target {
        case .native:
            stdout = try buildAndRunNative(workspace: workspace)
        case .embeddedWasm:
            stdout = try buildAndRunEmbedded(workspace: workspace)
        }
        return try decodeFrames(stdout)
    }

    /// Generates `template` (with `#sourceLocation` directives on) and compiles it
    /// natively, returning whether it built and the compiler's combined output.
    /// Used to prove that template type errors surface against the `.plume` source.
    static func compileDiagnostics(
        template: String,
        sourceName: String,
        fixtures: String,
        call: String
    ) throws -> (succeeded: Bool, output: String) {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources/app")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        try packageManifest(target: .native).write(
            to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try fixtures.write(
            to: sources.appendingPathComponent("Fixtures.swift"), atomically: true, encoding: .utf8)
        let swift = try PlumeSwiftBackend.generate(
            source: template, sourceName: sourceName,
            options: PlumeSwiftOptions(emitSourceLocations: true))
        try swift.write(
            to: sources.appendingPathComponent("Views.swift"), atomically: true, encoding: .utf8)
        try mainSource(cases: [RenderCase(name: "case", template: template, call: call)]).write(
            to: sources.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)

        let build = try run(
            "/usr/bin/env", ["swift", "build", "--package-path", workspace.path], cwd: workspace)
        let output =
            String(decoding: build.stdout, as: UTF8.self)
            + String(decoding: build.stderr, as: UTF8.self)
        return (build.exit == 0, output)
    }

    /// True when the Embedded-Wasm SDK and a Node runtime are both present.
    static func embeddedToolchainAvailable() -> Bool {
        guard which("node") != nil else { return false }
        guard let listing = try? run(
            "/usr/bin/env", ["swift", "sdk", "list"], cwd: nil), listing.exit == 0 else {
            return false
        }
        return String(decoding: listing.stdout, as: UTF8.self).contains(embeddedSDK)
    }

    // MARK: - Package scaffolding

    private static func packageManifest(target: RenderTarget) -> String {
        let repo = repoRoot().path
        return """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "plume-render-harness",
            platforms: [.macOS(.v14)],
            dependencies: [.package(name: "PlumeKit", path: \(swiftLiteral(repo)))],
            targets: [
                .executableTarget(
                    name: "app",
                    dependencies: [.product(name: "PlumeRuntime", package: "PlumeKit")]
                )
            ]
        )
        """
    }

    private static func mainSource(cases: [RenderCase]) -> String {
        var body = ""
        for renderCase in cases {
            body += """
                do {
                    var out = HTML()
                    \(renderCase.call)
                    appendFrame(&stream, name: \(swiftLiteral(renderCase.name)), content: out.bytes)
                }

            """
        }
        return """
        #if canImport(WASILibc)
        import WASILibc
        #endif
        import PlumeRuntime

        // The host-provided asset resolver generated code references for bundle
        // requirements (in a real app the build bakes these to hashed literals).
        func asset(_ name: String) -> String { "/" + name }

        func appendUInt32(_ stream: inout [UInt8], _ value: UInt32) {
            stream.append(UInt8(truncatingIfNeeded: value >> 24))
            stream.append(UInt8(truncatingIfNeeded: value >> 16))
            stream.append(UInt8(truncatingIfNeeded: value >> 8))
            stream.append(UInt8(truncatingIfNeeded: value))
        }

        func appendFrame(_ stream: inout [UInt8], name: String, content: [UInt8]) {
            let nameBytes = Array(name.utf8)
            appendUInt32(&stream, UInt32(nameBytes.count))
            stream.append(contentsOf: nameBytes)
            appendUInt32(&stream, UInt32(content.count))
            stream.append(contentsOf: content)
        }

        @main
        struct Main {
            static func main() {
                var stream = [UInt8]()
        \(body)
        #if canImport(WASILibc)
                stream.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count) }
        #else
                FileHandle.standardOutput.write(Data(stream))
        #endif
            }
        }

        #if !canImport(WASILibc)
        import Foundation
        #endif
        """
    }

    // MARK: - Build & run

    private static func buildAndRunNative(workspace: URL) throws -> Data {
        let build = try run(
            "/usr/bin/env", ["swift", "build", "--package-path", workspace.path],
            cwd: workspace)
        guard build.exit == 0 else {
            throw RenderHarnessError.buildFailed(String(decoding: build.stderr, as: UTF8.self))
        }
        let binary = workspace.appendingPathComponent(".build/debug/app")
        let result = try run(binary.path, [], cwd: workspace)
        guard result.exit == 0 else {
            throw RenderHarnessError.runFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result.stdout
    }

    private static func buildAndRunEmbedded(workspace: URL) throws -> Data {
        guard let node = which("node") else {
            throw RenderHarnessError.toolchainUnavailable("node not found")
        }
        let build = try run(
            "/usr/bin/env",
            ["swift", "build", "--package-path", workspace.path, "--swift-sdk", embeddedSDK],
            cwd: workspace)
        guard build.exit == 0 else {
            throw RenderHarnessError.buildFailed(String(decoding: build.stderr, as: UTF8.self))
        }
        let wasm = workspace.appendingPathComponent(
            ".build/wasm32-unknown-wasip1/debug/app.wasm")
        let runner = workspace.appendingPathComponent("run.mjs")
        try wasiRunner.write(to: runner, atomically: true, encoding: .utf8)
        let result = try run(node, [runner.path, wasm.path], cwd: workspace)
        guard result.exit == 0 else {
            throw RenderHarnessError.runFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result.stdout
    }

    private static let wasiRunner = """
        import { WASI } from 'node:wasi';
        import { readFile } from 'node:fs/promises';
        const wasi = new WASI({ version: 'preview1', args: ['app'], env: {}, returnOnExit: true });
        const bytes = await readFile(process.argv[2]);
        const module = await WebAssembly.compile(bytes);
        const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
        const code = wasi.start(instance);
        if (code !== 0) { process.stderr.write('exit ' + code + '\\n'); process.exit(code); }
        """

    // MARK: - Frame decoding

    private static func decodeFrames(_ data: Data) throws -> [String: [UInt8]] {
        let bytes = [UInt8](data)
        var cursor = 0
        var result: [String: [UInt8]] = [:]
        func readUInt32() throws -> Int {
            guard cursor + 4 <= bytes.count else {
                throw RenderHarnessError.runFailed("truncated frame stream")
            }
            let value =
                (Int(bytes[cursor]) << 24) | (Int(bytes[cursor + 1]) << 16)
                | (Int(bytes[cursor + 2]) << 8) | Int(bytes[cursor + 3])
            cursor += 4
            return value
        }
        while cursor < bytes.count {
            let nameLength = try readUInt32()
            guard cursor + nameLength <= bytes.count else {
                throw RenderHarnessError.runFailed("truncated name")
            }
            let name = String(decoding: bytes[cursor..<cursor + nameLength], as: UTF8.self)
            cursor += nameLength
            let contentLength = try readUInt32()
            guard cursor + contentLength <= bytes.count else {
                throw RenderHarnessError.runFailed("truncated content")
            }
            result[name] = Array(bytes[cursor..<cursor + contentLength])
            cursor += contentLength
        }
        return result
    }

    // MARK: - Process utilities

    private struct ProcessResult {
        var exit: Int32
        var stdout: Data
        var stderr: Data
    }

    private static func run(_ launchPath: String, _ arguments: [String], cwd: URL?) throws
        -> ProcessResult
    {
        let process = Process()
        if launchPath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath] + arguments
        }
        if process.arguments == nil { process.arguments = arguments }
        if let cwd { process.currentDirectoryURL = cwd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Read before waiting to avoid deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(exit: process.terminationStatus, stdout: outData, stderr: errData)
    }

    private static func which(_ tool: String) -> String? {
        guard let result = try? run("/usr/bin/env", ["which", tool], cwd: nil), result.exit == 0
        else {
            return nil
        }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Paths & literals

    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plume-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func swiftLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"") + "\""
    }
}

private func swiftLiteral(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
}
