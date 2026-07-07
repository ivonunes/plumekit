//
//  PlumeClientRuntimeTests.swift
//  PlumeTests — client drive runtime
//
//  Drives the jsdom behavioural harness (Tests/ClientRuntime/runtime.test.mjs)
//  against the shipped client runtime: dumps `PlumeBrowserRuntime.javaScript` and
//  runs the harness, which exercises apply/morph/frames/forms in a real DOM and
//  exits non-zero on any failed assertion. Skips when node or jsdom is absent.
//

import Foundation
import Testing

@testable import Plume

@Suite struct PlumeClientRuntimeTests {
    static var harnessDirectory: URL {
        RenderHarness.repoRoot().appendingPathComponent("Tests/ClientRuntime")
    }

    static var toolingAvailable: Bool {
        let fileManager = FileManager.default
        let jsdom = harnessDirectory.appendingPathComponent("node_modules/jsdom")
        guard fileManager.fileExists(atPath: jsdom.path) else { return false }
        return which("node") != nil
    }

    @Test(.enabled(if: PlumeClientRuntimeTests.toolingAvailable))
    func clientRuntimeBehavesInTheDOM() throws {
        let directory = Self.harnessDirectory
        let runtime = directory.appendingPathComponent("runtime.js")
        try PlumeBrowserRuntime.javaScript.write(to: runtime, atomically: true, encoding: .utf8)

        let result = try run(
            which("node")!, ["runtime.test.mjs", "runtime.js"], cwd: directory)
        let output =
            String(decoding: result.stdout, as: UTF8.self)
            + String(decoding: result.stderr, as: UTF8.self)
        #expect(result.exit == 0, "client runtime DOM checks failed:\n\(output)")
    }

    // MARK: - Process helpers

    private struct ProcessResult { var exit: Int32; var stdout: Data; var stderr: Data }

    private func run(_ launchPath: String, _ arguments: [String], cwd: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(exit: process.terminationStatus, stdout: outData, stderr: errData)
    }

    private static func which(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func which(_ tool: String) -> String? { Self.which(tool) }
}
