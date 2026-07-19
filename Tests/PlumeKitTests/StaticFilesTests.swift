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

    @Test func looksUpFileWithTypeSizeAndValidators() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let css = "body { color: red }"
        try css.write(toFile: dir + "/styles.css", atomically: true, encoding: .utf8)

        let root = try #require(StaticFiles.resolveRoot(dir))
        let info = try #require(StaticFiles.lookup(requestPath: "/styles.css", root: root))
        #expect(info.contentType.contains("text/css"))
        #expect(info.size == css.utf8.count)
        #expect(!info.cacheControl.isEmpty)
        #expect(info.etag.hasPrefix("W/\""))
        #expect(info.lastModified.hasSuffix("GMT"))
    }

    @Test func looksUpNestedPathWithBinaryContentType() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/img", withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: dir + "/img/logo.png"))

        let root = try #require(StaticFiles.resolveRoot(dir))
        let info = try #require(StaticFiles.lookup(requestPath: "/img/logo.png", root: root))
        #expect(info.contentType == "image/png")
        #expect(info.size == 4)
    }

    @Test func missingFileFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = try #require(StaticFiles.resolveRoot(dir))
        #expect(StaticFiles.lookup(requestPath: "/nope.css", root: root) == nil)
    }

    @Test func missingRootResolvesToNil() throws {
        #expect(StaticFiles.resolveRoot("/no/such/directory/plume") == nil)
    }

    @Test func directoryIsNotServed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        let root = try #require(StaticFiles.resolveRoot(dir))
        #expect(StaticFiles.lookup(requestPath: "/sub", root: root) == nil)
    }

    @Test func pathTraversalIsBlocked() throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let publicDir = tempRoot + "/Public"
        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        // A secret sibling of Public/, reachable only by escaping the root with `..`.
        try "TOPSECRET".write(toFile: tempRoot + "/secret.txt", atomically: true, encoding: .utf8)

        let root = try #require(StaticFiles.resolveRoot(publicDir))
        #expect(StaticFiles.lookup(requestPath: "/../secret.txt", root: root) == nil)
        #expect(StaticFiles.lookup(requestPath: "/..%2Fsecret.txt", root: root) == nil)
    }

    @Test func symlinkEscapingTheRootIsNotServed() throws {
        let tempRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let publicDir = tempRoot + "/Public"
        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        try "TOPSECRET".write(toFile: tempRoot + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: publicDir + "/leak.txt",
                                                   withDestinationPath: tempRoot + "/secret.txt")
        let root = try #require(StaticFiles.resolveRoot(publicDir))
        #expect(StaticFiles.lookup(requestPath: "/leak.txt", root: root) == nil)
    }

    @Test func etagChangesWithContent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "one".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let root = try #require(StaticFiles.resolveRoot(dir))
        let first = try #require(StaticFiles.lookup(requestPath: "/a.txt", root: root))
        try "three!".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let second = try #require(StaticFiles.lookup(requestPath: "/a.txt", root: root))
        #expect(first.etag != second.etag)   // size differs even when mtime granularity hides the write
    }
}
