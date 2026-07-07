import Foundation
import PlumeCore

/// Native StorageDriver: one file per key under a directory. The native reference's
/// object storage — real and deployable, no managed platform underneath.
public actor FileStorage: StorageDriver {
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

    public func delete(_ key: String) {
        try? FileManager.default.removeItem(atPath: path(for: key))
    }
}
