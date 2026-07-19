import Foundation
import PlumeCore

/// Native StorageDriver: one file per key under a directory. The native reference's
/// object storage — real and deployable, no managed platform underneath.
public actor FileStorage: StreamingStorageDriver {
    private let directory: String

    public init(directory: String) {
        self.directory = directory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func path(for key: String) -> String {
        directory + "/" + safeStoreFilename(key)
    }

    public func get(_ key: String) -> [UInt8]? {
        guard let data = FileManager.default.contents(atPath: path(for: key)) else { return nil }
        return [UInt8](data)
    }

    public func put(_ key: String, _ bytes: [UInt8]) {
        _ = FileManager.default.createFile(atPath: path(for: key), contents: Data(bytes))
    }

    /// Stream chunks straight to disk. Written to a temp sibling and renamed on
    /// completion, so a failed/disconnected upload never leaves a half-written
    /// object readable at its key.
    public func put(_ key: String, from reader: RequestBodyReader) async throws {
        let final = path(for: key)
        let partial = final + ".partial"
        guard FileManager.default.createFile(atPath: partial, contents: nil),
              let handle = FileHandle(forWritingAtPath: partial) else {
            throw StorageWriteFailed(path: partial)
        }
        do {
            while let chunk = try await reader.next() {
                try handle.write(contentsOf: Data(chunk))
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: final) {
                try FileManager.default.removeItem(atPath: final)
            }
            try FileManager.default.moveItem(atPath: partial, toPath: final)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(atPath: partial)
            throw error
        }
    }

    public func delete(_ key: String) {
        try? FileManager.default.removeItem(atPath: path(for: key))
    }
}

/// The filesystem store couldn't open its temp file for a streamed write.
public struct StorageWriteFailed: Error, CustomStringConvertible {
    let path: String
    public var description: String { "storage: cannot write \(path)" }
}
