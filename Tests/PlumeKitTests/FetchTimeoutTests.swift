import Foundation
import Testing

@testable import PlumeCore
@testable import PlumeServer

// A per-request timeout has to reach the adapter that makes the call: the native
// client's URLRequest, and the Cloudflare host's fetch (over the wire).

@Suite struct FetchTimeoutTests {
    @Test func nativeClientHonoursTheRequestedTimeout() throws {
        let request = FetchRequest(method: "POST", url: "https://example.test/generate",
                                   timeoutSeconds: 300)
        let urlRequest = try URLSessionHTTPClient.urlRequest(for: request)
        #expect(urlRequest.timeoutInterval == 300)
    }

    @Test func nativeClientFallsBackToTheDefaultTimeout() throws {
        let urlRequest = try URLSessionHTTPClient.urlRequest(
            for: FetchRequest(url: "https://example.test/"))
        #expect(urlRequest.timeoutInterval == TimeInterval(FetchRequest.defaultTimeoutSeconds))
    }

    @Test func wireCarriesTheTimeoutToTheHost() {
        let encoded = FetchWire.encodeRequest(
            FetchRequest(url: "https://example.test/", body: [1, 2, 3], timeoutSeconds: 300))
        #expect(trailingTimeout(encoded) == 300)
    }

    @Test func wireSendsZeroWhenNoTimeoutIsAsked() {
        let encoded = FetchWire.encodeRequest(FetchRequest(url: "https://example.test/"))
        #expect(trailingTimeout(encoded) == 0)
    }

    /// The `[u32 timeoutSeconds]` the wire appends after the body.
    private func trailingTimeout(_ bytes: [UInt8]) -> Int {
        let i = bytes.count - 4
        return Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
    }
}
