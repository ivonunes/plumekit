import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif
@testable import PlumeServer
@testable import PlumeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `SOCK_STREAM` is an `Int32` on Darwin but a `__socket_type` enum on Glibc; normalise it.
#if canImport(Glibc)
private let sockStream = Int32(SOCK_STREAM.rawValue)
#else
private let sockStream = SOCK_STREAM
#endif

// Live-socket tests of the native server's connection loop — the one code path with no
// unit coverage. They start a real PlumeServer, so they also guard the slow-loris
// watchdog + task-group restructure against breaking normal serving.

/// A free localhost TCP port (bind :0, read the assignment, release). A tiny TOCTOU
/// window, acceptable for a test.
private func freePort() -> UInt16 {
    let fd = socket(AF_INET, sockStream, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    _ = withUnsafeMutablePointer(to: &bound) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    close(fd)
    return UInt16(bigEndian: bound.sin_port)
}

@Test func serverServesNormalRequestsAndCustomErrorPages() async throws {
    let app = Application()
    app.get("/") { _ in .text("hello-plume") }
    app.errorPage(404) { _ in .html("<h1>nope</h1>", status: 404) }
    let port = freePort()
    let server = Task { try? await PlumeServer.run(app, host: "127.0.0.1", port: port) }
    defer { server.cancel() }
    try await Task.sleep(nanoseconds: 500 * 1_000_000)   // let it bind

    // Normal GET over the wire — exercises the real connection loop end-to-end.
    let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
    #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "hello-plume")

    // Custom 404 page over the wire (validates the error-page feature through the adapter).
    let (nfData, nfResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/missing")!)
    #expect((nfResp as? HTTPURLResponse)?.statusCode == 404)
    #expect(String(decoding: nfData, as: UTF8.self) == "<h1>nope</h1>")
}

@Test func slowClientWithNoCompleteHeadIsClosed() async throws {
    let app = Application()
    app.get("/") { _ in .text("ok") }
    let previous = PlumeServer.requestHeadTimeoutMillis
    PlumeServer.requestHeadTimeoutMillis = 500          // short window for the test
    defer { PlumeServer.requestHeadTimeoutMillis = previous }
    let port = freePort()
    let server = Task { try? await PlumeServer.run(app, host: "127.0.0.1", port: port) }
    defer { server.cancel() }
    try await Task.sleep(nanoseconds: 500 * 1_000_000)

    // Connect and send a partial request — never the blank line, so the head never completes.
    // Retry with a fresh socket: under parallel tests on a loaded runner the NIO server may
    // not be listening yet, so a one-shot connect can hit ECONNREFUSED. A failed connect can
    // leave the socket unusable, so discard and remake it each attempt.
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = port.bigEndian
    var fd: Int32 = -1
    for _ in 0..<50 {
        fd = socket(AF_INET, sockStream, 0)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { break }
        close(fd)
        fd = -1
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = "GET / HTTP/1.1\r\nHost: x\r\n".withCString { send(fd, $0, strlen($0), 0) }   // no terminating blank line

    // A blocking read must hit EOF (server closed us) within a couple of windows, not hang.
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = [UInt8](repeating: 0, count: 64)
    let n = recv(fd, &buf, buf.count, 0)
    #expect(n == 0)   // 0 = orderly EOF: the slow-loris guard closed the connection
}

@Test func completeRequestWithASlowHandlerSurvivesTheTimeout() async throws {
    // Proves the timeout is cancelled once headers complete: a request whose handler runs
    // LONGER than the window still returns (the guard must not kill an in-flight request —
    // the same property that keeps SSE/WebSocket streams alive).
    let app = Application()
    app.get("/slow") { _ in
        try? await Task.sleep(nanoseconds: 900 * 1_000_000)   // > the 400ms window below
        return .text("finished")
    }
    let previous = PlumeServer.requestHeadTimeoutMillis
    PlumeServer.requestHeadTimeoutMillis = 400
    defer { PlumeServer.requestHeadTimeoutMillis = previous }
    let port = freePort()
    let server = Task { try? await PlumeServer.run(app, host: "127.0.0.1", port: port) }
    defer { server.cancel() }
    try await Task.sleep(nanoseconds: 500 * 1_000_000)

    let (data, resp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/slow")!)
    #expect((resp as? HTTPURLResponse)?.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == "finished")
}
