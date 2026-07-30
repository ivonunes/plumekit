//
//  WorkerRuntimeGateTests.swift
//  PlumeKitTests — Cloudflare worker runtime
//
//  Drives the node harness (Tests/WorkerRuntime/gate.test.mjs) against the
//  shipped runtime/cloudflare/worker.mjs: the guest gate serializes calls, and
//  survives the runtime dropping one mid-flight. Skips when node is absent.
//

import Foundation
import Testing

@Suite struct WorkerRuntimeGateTests {
    static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    @Test(.enabled(if: which("node") != nil))
    func guestGateSerializesAndRecovers() throws {
        let directory = Self.repoRoot.appendingPathComponent("Tests/WorkerRuntime")
        let worker = Self.repoRoot.appendingPathComponent("runtime/cloudflare/worker.mjs")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: which("node")!)
        process.arguments = ["gate.test.mjs", worker.path]
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            + String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "worker runtime gate checks failed:\n\(output)")
    }
}

private func which(_ tool: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", tool]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil : path.trimmingCharacters(in: .whitespacesAndNewlines)
}
