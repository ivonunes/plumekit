import Testing
@testable import PlumeServer

@Suite struct CompressionTests {
    @Test func gzipShrinksTextAndCarriesTheMagicHeader() {
        let text = [UInt8](String(repeating: "plumekit compresses responses. ", count: 200).utf8)
        let compressed = GzipCompression.gzip(text)
        let out = try! #require(compressed)
        #expect(out.count < text.count / 4)
        #expect(out.prefix(2) == [0x1F, 0x8B])   // gzip magic
        #expect(out[2] == 8)                     // deflate method
    }

    @Test func emptyInputStillProducesAValidFrame() {
        let out = try! #require(GzipCompression.gzip([]))
        #expect(out.prefix(2) == [0x1F, 0x8B])
    }

    @Test func contentTypeGatekeeping() {
        #expect(GzipCompression.isCompressibleContentType("text/html; charset=utf-8"))
        #expect(GzipCompression.isCompressibleContentType("application/json"))
        #expect(GzipCompression.isCompressibleContentType("image/svg+xml"))
        #expect(!GzipCompression.isCompressibleContentType("image/png"))
        #expect(!GzipCompression.isCompressibleContentType("font/woff2"))
        #expect(!GzipCompression.isCompressibleContentType("application/wasm"))
        #expect(!GzipCompression.isCompressibleContentType("text/event-stream"))
    }
}

@Suite struct GzipAssetCacheTests {
    @Test func storesAndServesByETag() {
        let cache = GzipAssetCache()
        cache.store("W/\"10-1\"", [1, 2, 3])
        #expect(cache.lookup("W/\"10-1\"") == [1, 2, 3])
        #expect(cache.lookup("W/\"10-2\"") == nil)   // changed file → different etag → miss
    }

    @Test func evictsOldestWhenOverTheByteCap() {
        let cache = GzipAssetCache(maxTotalBytes: 10)
        cache.store("a", [UInt8](repeating: 1, count: 6))
        cache.store("b", [UInt8](repeating: 2, count: 6))   // 12 > 10 → evicts "a"
        #expect(cache.lookup("a") == nil)
        #expect(cache.lookup("b") != nil)
    }

    @Test func oversizedEntriesAreNeverStored() {
        let cache = GzipAssetCache(maxTotalBytes: 4)
        cache.store("big", [UInt8](repeating: 0, count: 5))
        #expect(cache.lookup("big") == nil)
    }
}
