import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif
@testable import PlumeCore
@testable import PlumeServer
@testable import PlumeS3

// Streaming writes into storage: the filesystem driver's chunk-to-disk path, the
// buffered fallback, and the S3 driver's multipart upload against a stub S3
// served by PlumeKit itself (request shapes; real-S3 behaviour is covered by the
// LocalStack workflow).

@Suite struct StorageStreamingTests {
    private func chunkReader(_ chunks: [[UInt8]]) -> RequestBodyReader {
        let box = ChunkBox(chunks)
        return RequestBodyReader { box.take() }
    }

    private final class ChunkBox: @unchecked Sendable {
        private var remaining: [[UInt8]]
        init(_ chunks: [[UInt8]]) { remaining = chunks }
        func take() -> [UInt8]? { remaining.isEmpty ? nil : remaining.removeFirst() }
    }

    @Test func fileStorageStreamsChunksToDisk() async throws {
        let dir = NSTemporaryDirectory() + "plume-storage-" + ProcessInfo.processInfo.globallyUniqueString
        let storage = NativeDrivers.filesystemStorage(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        try await storage.put("upload.bin", from: chunkReader([[1, 2], [3], [4, 5, 6]]))
        #expect(try await storage.get("upload.bin") == [1, 2, 3, 4, 5, 6])
    }

    @Test func fileStorageFailedStreamLeavesNoObject() async throws {
        let dir = NSTemporaryDirectory() + "plume-storage-" + ProcessInfo.processInfo.globallyUniqueString
        let storage = NativeDrivers.filesystemStorage(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        struct Cut: Error {}
        let box = ChunkBox([[1, 2, 3]])
        let reader = RequestBodyReader {
            if let chunk = box.take() { return chunk }
            throw Cut()   // the connection died mid-upload
        }
        await #expect(throws: Cut.self) {
            try await storage.put("half.bin", from: reader)
        }
        // Neither the object nor a partial file is visible at the key.
        #expect(try await storage.get("half.bin") == nil)
    }

    @Test func bufferedDriversFallBackToOnePut() async throws {
        let storage = NativeDrivers.memoryStorage()   // StorageDriver only — fallback init
        try await storage.put("k", from: chunkReader([[9], [8, 7]]))
        #expect(try await storage.get("k") == [9, 8, 7])
    }
}

// MARK: - S3 multipart against a stub

@Suite(.serialized) struct S3MultipartTests {
    /// A minimal S3 imitation: plain PUT, CreateMultipartUpload, UploadPart,
    /// CompleteMultipartUpload — enough to assert the driver's request shapes and
    /// the assembled object.
    private static func makeFakeS3(into store: FakeS3State) -> Application {
        let app = Application()
        app.post("/bucket/**key") { request in
            let key = request.parameters["key"] ?? ""
            if request.queryParams["uploads"] != nil {
                await store.begin(key: key)
                return .text("<InitiateMultipartUploadResult><UploadId>upload-1</UploadId></InitiateMultipartUploadResult>")
            }
            if request.queryParams["uploadId"] != nil {
                await store.complete(key: key)
                return .text("<CompleteMultipartUploadResult/>")
            }
            return .status(400)
        }
        app.put("/bucket/**key") { request in
            let key = request.parameters["key"] ?? ""
            if let partNumber = request.queryParams.int("partNumber"),
               request.queryParams["uploadId"] != nil {
                await store.addPart(key: key, number: partNumber, bytes: request.body)
                var response = Response.text("")
                response.headers.set("etag", "\"part-\(partNumber)\"")
                return response
            }
            await store.putWhole(key: key, bytes: request.body)
            return .text("")
        }
        return app
    }

    actor FakeS3State {
        var whole: [String: [UInt8]] = [:]
        var parts: [Int: [UInt8]] = [:]
        var multipartUsed = false
        func begin(key: String) { multipartUsed = true; parts = [:] }
        func addPart(key: String, number: Int, bytes: [UInt8]) { parts[number] = bytes }
        func complete(key: String) {
            whole[key] = parts.keys.sorted().flatMap { parts[$0] ?? [] }
        }
        func putWhole(key: String, bytes: [UInt8]) { whole[key] = bytes }
    }

    private func startFakeS3(_ store: FakeS3State, port: UInt16) async throws {
        let app = Self.makeFakeS3(into: store)
        Task { try await PlumeServer.run(app, host: "127.0.0.1", port: port) }
        // Poll with a deadline, not a fixed sleep.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let url = URL(string: "http://127.0.0.1:\(port)/bucket/probe"),
               (try? await URLSession.shared.data(from: url)) != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("fake S3 never came up")
    }

    private func reader(totalBytes: Int, chunkBytes: Int) -> RequestBodyReader {
        let box = CountBox(total: totalBytes, chunk: chunkBytes)
        return RequestBodyReader { box.take() }
    }

    private final class CountBox: @unchecked Sendable {
        private var remaining: Int
        private let chunk: Int
        init(total: Int, chunk: Int) { remaining = total; self.chunk = chunk }
        func take() -> [UInt8]? {
            guard remaining > 0 else { return nil }
            let n = min(chunk, remaining)
            remaining -= n
            return [UInt8](repeating: 0x42, count: n)
        }
    }

    @Test func smallStreamGoesUpAsOnePlainPut() async throws {
        let store = FakeS3State()
        try await startFakeS3(store, port: 8271)
        let s3 = S3Storage(endpoint: "http://127.0.0.1:8271", region: "us-east-1",
                           bucket: "bucket", accessKey: "k", secretKey: "s")
        try await s3.put("small.bin", from: reader(totalBytes: 100_000, chunkBytes: 32_768))
        #expect(await store.whole["small.bin"]?.count == 100_000)
        #expect(await store.multipartUsed == false)
    }

    @Test func largeStreamBecomesAMultipartUpload() async throws {
        let store = FakeS3State()
        try await startFakeS3(store, port: 8272)
        let s3 = S3Storage(endpoint: "http://127.0.0.1:8272", region: "us-east-1",
                           bucket: "bucket", accessKey: "k", secretKey: "s")
        let total = 20 * 1024 * 1024   // 8 MB + 8 MB + 4 MB parts
        try await s3.put("big.bin", from: reader(totalBytes: total, chunkBytes: 1 << 20))
        #expect(await store.multipartUsed)
        #expect(await store.whole["big.bin"]?.count == total)
        #expect(await store.parts.count == 3)
        #expect(await store.parts[1]?.count == S3Storage.multipartPartBytes)
        #expect(await store.parts[3]?.count == 4 * 1024 * 1024)
    }
}
