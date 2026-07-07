import Testing
@testable import PlumeCore
import PlumeServer

@Test func memoryCacheRoundTrips() async throws {
    let cache = NativeDrivers.memoryCache()

    #expect(try await cache.get("absent") == nil)

    try await cache.set("k", Array("v1".utf8))
    #expect(try await cache.getString("k") == "v1")

    // Overwrite.
    try await cache.setString("k", "v2")
    #expect(try await cache.getString("k") == "v2")

    try await cache.set("bin", [0, 1, 2, 255])
    #expect(try await cache.get("bin") == [0, 1, 2, 255])

    try await cache.delete("k")
    #expect(try await cache.get("k") == nil)
}

@Test func memoryCacheTTLPresentBeforeExpiry() async throws {
    let cache = NativeDrivers.memoryCache()
    // A generous TTL: the entry is still live when we immediately read it back.
    try await cache.setString("k", "v", ttlSeconds: 3600)
    #expect(try await cache.getString("k") == "v")
}
