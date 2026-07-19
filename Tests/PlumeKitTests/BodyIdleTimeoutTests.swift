import Testing
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import PlumeServer

// The body-idle guard, driven deterministically on an embedded event loop.

@Suite struct BodyIdleTimeoutTests {
    private func makeChannel(timeoutMillis: Int64) throws -> (EmbeddedChannel, EmbeddedEventLoop) {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            handler: RequestBodyIdleTimeout(timeout: .milliseconds(timeoutMillis)), loop: loop)
        // An embedded channel starts inactive; connect so `isActive` means something.
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        return (channel, loop)
    }

    private var head: HTTPServerRequestPart {
        .head(HTTPRequestHead(version: .http1_1, method: .POST, uri: "/upload"))
    }

    private var chunk: HTTPServerRequestPart {
        .body(ByteBuffer(bytes: [1, 2, 3]))
    }

    @Test func stalledBodyClosesTheConnection() throws {
        let (channel, loop) = try makeChannel(timeoutMillis: 1000)
        try channel.writeInbound(head)
        loop.advanceTime(by: .milliseconds(1500))
        #expect(!channel.isActive)
    }

    @Test func steadyChunksKeepResettingTheClock() throws {
        let (channel, loop) = try makeChannel(timeoutMillis: 1000)
        try channel.writeInbound(head)
        for _ in 0..<5 {
            loop.advanceTime(by: .milliseconds(800))   // under the limit each time
            try channel.writeInbound(chunk)
        }
        #expect(channel.isActive)   // 4s total, but never 1s without progress
        loop.advanceTime(by: .milliseconds(1500))      // now stall
        #expect(!channel.isActive)
    }

    @Test func endDisarmsForHandlerTimeAndKeepAliveIdle() throws {
        let (channel, loop) = try makeChannel(timeoutMillis: 1000)
        try channel.writeInbound(head)
        try channel.writeInbound(chunk)
        try channel.writeInbound(HTTPServerRequestPart.end(nil))
        // A slow handler or an idle keep-alive gap must NOT be treated as a stall.
        loop.advanceTime(by: .seconds(60))
        #expect(channel.isActive)
        // The next request arms it again.
        try channel.writeInbound(head)
        loop.advanceTime(by: .milliseconds(1500))
        #expect(!channel.isActive)
    }
}
