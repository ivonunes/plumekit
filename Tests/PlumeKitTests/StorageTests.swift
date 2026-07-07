import Testing
import Foundation
@testable import PlumeCore
import PlumeServer

@Test func fileStorageDriverRoundTrips() async throws {
    let dir = NSTemporaryDirectory() + "plumekit-blobtest-\(UInt32.random(in: 0..<UInt32.max))"
    let store = FileStorage(directory: dir)
    let handle = Storage(store)

    #expect(try await handle.get("absent") == nil)
    try await handle.put("greeting", Array("hello & <blobs>".utf8))
    #expect(try await handle.get("greeting").map { PlumeCore.decodeUTF8($0) } == "hello & <blobs>")

    try await handle.put("bin", [0, 1, 2, 255])
    #expect(try await handle.get("bin") == [0, 1, 2, 255])

    try await handle.delete("greeting")
    #expect(try await handle.get("greeting") == nil)
}
