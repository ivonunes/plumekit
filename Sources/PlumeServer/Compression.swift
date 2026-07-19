import CZlib
import Foundation
import PlumeCore

// gzip response compression for the native server, on the vendored zlib deflate
// (ThirdParty/CZlib — no system zlib anywhere, matching CSQLite). Compression
// happens at the response-writing layer, not a channel handler: the server knows
// the content type and the request's Accept-Encoding, so only bodies that
// actually shrink (text-ish types) pay for it.

enum GzipCompression {
    /// Only compress bodies at least this large — below it the gzip header/frame
    /// overhead and CPU outweigh the saving on a LAN-fast link.
    static let minimumBytes = 512

    /// gzip `bytes` (deflate with the gzip wrapper, default level), or nil if
    /// zlib fails (callers then send identity — never a broken response).
    static func gzip(_ bytes: [UInt8]) -> [UInt8]? {
        var stream = z_stream()
        // windowBits 15 + 16 selects the gzip wrapper; memLevel 8 is zlib's default.
        let initResult = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                       15 + 16, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(bytes.count)))
        var output = [UInt8](repeating: 0, count: bound)
        var produced = 0
        var input = bytes   // var: z_stream wants a mutable next_in
        let status: Int32 = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                let result = deflate(&stream, Z_FINISH)
                produced = outBuffer.count - Int(stream.avail_out)
                return result
            }
        }
        guard status == Z_STREAM_END else { return nil }
        output.removeLast(output.count - produced)
        return output
    }

    /// Gzipped static assets, keyed by ETag — the same bundle is requested on
    /// every page view, and deflating it per request is pure waste. The ETag
    /// encodes size + mtime, so an edited file simply misses into a fresh entry;
    /// superseded entries age out via the byte-bounded FIFO below.
    static let assetCache = GzipAssetCache()

    /// Whether the request accepts gzip (`Accept-Encoding: gzip` / `…, gzip;q=…`).
    /// A `q=0` opt-out is treated as acceptance — no real client sends it.
    static func requestAcceptsGzip(_ headers: Headers) -> Bool {
        guard let accept = headers.first("accept-encoding") else { return false }
        return utf8Contains(accept.lowercased(), "gzip")
    }

    /// Compress only what shrinks: text-ish content types. Images, fonts, wasm and
    /// archives are already compressed — gzipping them costs CPU for nothing.
    /// Event streams are excluded (SSE messages must flush immediately).
    static func isCompressibleContentType(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.hasPrefix("text/") {
            return !lowered.hasPrefix("text/event-stream")
        }
        for prefix in ["application/json", "application/javascript", "application/manifest+json",
                       "application/xml", "image/svg+xml"]
        where lowered.hasPrefix(prefix) {
            return true
        }
        return false
    }
}

extension GzipCompression {
    /// Incremental gzip for streamed responses. Each producer chunk is deflated
    /// with `Z_SYNC_FLUSH`, so its compressed form reaches the client immediately
    /// (a progress line still shows up as it's written) at a small ratio cost;
    /// `finish()` emits the gzip trailer. `@unchecked Sendable`: one instance per
    /// response, driven sequentially by that response's writer — never shared.
    final class Streamer: @unchecked Sendable {
        private var stream = z_stream()
        private var alive: Bool

        init?() {
            let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                       15 + 16, 8, Z_DEFAULT_STRATEGY,
                                       ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { return nil }
            alive = true
        }

        deinit {
            if alive { deflateEnd(&stream) }
        }

        /// Deflate one chunk, flushed so it decodes standalone at the client.
        func push(_ bytes: [UInt8]) -> [UInt8]? {
            run(input: bytes, mode: Z_SYNC_FLUSH, expectEnd: false)
        }

        /// Emit whatever zlib still holds plus the gzip trailer, and tear down.
        func finish() -> [UInt8]? {
            defer {
                if alive { deflateEnd(&stream); alive = false }
            }
            return run(input: [], mode: Z_FINISH, expectEnd: true)
        }

        private func run(input: [UInt8], mode: Int32, expectEnd: Bool) -> [UInt8]? {
            guard alive else { return nil }
            var output: [UInt8] = []
            var chunk = input   // z_stream wants mutable next_in
            var scratch = [UInt8](repeating: 0, count: max(16 * 1024, input.count + 64))
            let ok: Bool = chunk.withUnsafeMutableBufferPointer { inBuffer in
                stream.next_in = inBuffer.baseAddress
                stream.avail_in = uInt(inBuffer.count)
                while true {
                    var produced = 0
                    var status: Int32 = Z_OK
                    scratch.withUnsafeMutableBufferPointer { outBuffer in
                        stream.next_out = outBuffer.baseAddress
                        stream.avail_out = uInt(outBuffer.count)
                        status = deflate(&stream, mode)
                        produced = outBuffer.count - Int(stream.avail_out)
                    }
                    if produced > 0 { output.append(contentsOf: scratch[0..<produced]) }
                    if expectEnd {
                        if status == Z_STREAM_END { return true }
                        if status != Z_OK && status != Z_BUF_ERROR { return false }
                        continue   // trailer needs another pass
                    }
                    guard status == Z_OK || status == Z_BUF_ERROR else { return false }
                    // A sync flush is complete once zlib stops filling the buffer.
                    if stream.avail_in == 0 && Int(stream.avail_out) > 0 { return true }
                }
            }
            return ok ? output : nil
        }
    }
}

/// A byte-bounded FIFO of gzipped bodies. FIFO (not LRU) is enough here: the
/// working set is a handful of bundle files, far under the cap; the bound only
/// exists so churn (deploys rotating hashed filenames) can't grow it forever.
final class GzipAssetCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [UInt8]] = [:]
    private var insertionOrder: [String] = []
    private var totalBytes = 0
    private let maxTotalBytes: Int

    init(maxTotalBytes: Int = 8 * 1024 * 1024) {
        self.maxTotalBytes = maxTotalBytes
    }

    func lookup(_ etag: String) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[etag]
    }

    func store(_ etag: String, _ bytes: [UInt8]) {
        guard bytes.count <= maxTotalBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        guard entries[etag] == nil else { return }
        entries[etag] = bytes
        insertionOrder.append(etag)
        totalBytes += bytes.count
        while totalBytes > maxTotalBytes, !insertionOrder.isEmpty {
            let oldest = insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalBytes -= removed.count }
        }
    }
}
