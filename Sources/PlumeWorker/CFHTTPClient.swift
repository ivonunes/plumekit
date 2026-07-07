// Cloudflare outbound HTTP — the global `fetch`, for the Wasm target. Async via
// JSPI; two-call read.
//   host_fetch_get:     GET-only fast path; result wire = [u16 status][body].
//   host_fetch_request: full fetch (method/headers/body) using FetchWire; result
//                       wire = [u16 status][u16 headerCount][headers…][body].
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

@_extern(wasm, module: "env", name: "host_fetch_get")
func host_fetch_get(_ ctx: Int32, _ urlPtr: UnsafePointer<UInt8>?, _ urlLen: Int32) -> Int32

@_extern(wasm, module: "env", name: "host_fetch_read")
func host_fetch_read(_ ctx: Int32, _ dstPtr: UnsafeMutablePointer<UInt8>?)

@_extern(wasm, module: "env", name: "host_fetch_request")
func host_fetch_request(_ ctx: Int32, _ reqPtr: UnsafePointer<UInt8>?, _ reqLen: Int32) -> Int32

struct CFHTTPClient: HTTPClient {
    let ctx: Int32

    func get(_ url: String) async throws -> FetchResponse {
        let urlBytes = Array(url.utf8)
        let len = urlBytes.withUnsafeBufferPointer { host_fetch_get(ctx, $0.baseAddress, Int32($0.count)) }
        if len < 0 { return FetchResponse(status: 0, body: []) }
        var buffer = [UInt8](repeating: 0, count: Int(len))
        if len > 0 { buffer.withUnsafeMutableBufferPointer { host_fetch_read(ctx, $0.baseAddress) } }
        let status = buffer.count >= 2 ? Int(buffer[0]) | (Int(buffer[1]) << 8) : 0
        let body = buffer.count > 2 ? Array(buffer[2...]) : []
        return FetchResponse(status: status, body: body)
    }

    func request(_ fetchRequest: FetchRequest) async throws -> FetchResponse {
        let wire = FetchWire.encodeRequest(fetchRequest)
        let len = wire.withUnsafeBufferPointer { host_fetch_request(ctx, $0.baseAddress, Int32($0.count)) }
        if len < 0 { return FetchResponse(status: 0, body: []) }
        var buffer = [UInt8](repeating: 0, count: Int(len))
        if len > 0 { buffer.withUnsafeMutableBufferPointer { host_fetch_read(ctx, $0.baseAddress) } }
        return FetchWire.decodeResponse(buffer)
    }
}
#endif
