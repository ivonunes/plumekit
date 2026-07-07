// Cloudflare Queues adapter — the Queue for the Wasm target. Enqueue only (the
// producer binding); consumers are the jobs layer. Async send via JSPI.
#if arch(wasm32)
@_spi(ExperimentalCustomExecutors) import _Concurrency
import PlumeCore

@_extern(wasm, module: "env", name: "host_queue_send")
func host_queue_send(_ ctx: Int32, _ bodyPtr: UnsafePointer<UInt8>?, _ bodyLen: Int32) -> Int32

struct CFQueue: MessageQueue {
    let ctx: Int32
    func send(_ body: [UInt8]) async throws {
        _ = body.withUnsafeBufferPointer { host_queue_send(ctx, $0.baseAddress, Int32($0.count)) }
    }
}
#endif
