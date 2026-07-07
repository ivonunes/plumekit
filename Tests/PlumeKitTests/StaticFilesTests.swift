import Testing
import Foundation
@testable import PlumeServer
import PlumeCore

@Suite struct StaticFilesTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "plume-static-" + ProcessInfo.processInfo.globallyUniqueString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func servesFileWithContentTypeAndBody() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "body { color: red }".write(toFile: dir + "/styles.css", atomically: true, encoding: .utf8)

        let response = StaticFiles.response(for: "/styles.css", in: dir)
        #expect(response?.status == 200)
        #expect(response?.headers.first("content-type")?.contains("text/css") == true)
        #expect(response?.headers.first("cache-control") != nil)
        #expect(String(decoding: response?.body ?? [], as: UTF8.self) == "body { color: red }")
    }

    @Test func servesNestedPathWithBinaryContentType() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/img", withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: dir + "/img/logo.png"))

        let response = StaticFiles.response(for: "/img/logo.png", in: dir)
        #expect(response?.status == 200)
        #expect(response?.headers.first("content-type") == "image/png")
    }

    @Test func missingFileFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(StaticFiles.response(for: "/nope.css", in: dir) == nil)
    }

    @Test func directoryIsNotServed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        #expect(StaticFiles.response(for: "/sub", in: dir) == nil)
    }

    @Test func pathTraversalIsBlocked() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let publicDir = root + "/Public"
        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        // A secret sibling of Public/, reachable only by escaping the root with `..`.
        try "TOPSECRET".write(toFile: root + "/secret.txt", atomically: true, encoding: .utf8)

        #expect(StaticFiles.response(for: "/../secret.txt", in: publicDir) == nil)
        #expect(StaticFiles.response(for: "/..%2Fsecret.txt", in: publicDir) == nil)
    }
}

extension StaticFilesTests {
    @Test func symlinkEscapingTheRootIsNotServed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let publicDir = root + "/Public"
        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        try "TOPSECRET".write(toFile: root + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: publicDir + "/leak.txt",
                                                   withDestinationPath: root + "/secret.txt")
        #expect(StaticFiles.response(for: "/leak.txt", in: publicDir) == nil)
    }
}
