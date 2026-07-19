import _Concurrency

// MARK: - The Storage capability (object storage)
//
// Object storage — opaque byte payloads addressed by key (files, uploads,
// exports), a structurally different shape from `Database`'s typed rows. Adapters:
// Cloudflare R2 (wasm, JSPI), a native filesystem store, and S3-compatible stores.
// Same protocol + handle pattern as `Database`: an adapter protocol, and an
// Embedded-clean handle that wraps `some StorageDriver` (never `any`).

/// What a storage adapter implements (R2, S3, filesystem…). Bytes are `[UInt8]`.
public protocol StorageDriver: DataStore {
    func get(_ key: String) async throws -> [UInt8]?
    func put(_ key: String, _ bytes: [UInt8]) async throws
    func delete(_ key: String) async throws
}

/// A driver that can also WRITE an object from a chunk stream without holding it
/// in memory (the filesystem store appends to the file; S3 does a multipart
/// upload). Drivers without this get a buffer-then-put fallback — resolved
/// statically at `Storage.init` (no dynamic casts, Embedded-clean).
public protocol StreamingStorageDriver: StorageDriver {
    func put(_ key: String, from reader: RequestBodyReader) async throws
}

/// The concrete, Embedded-clean object-storage handle carried in `Context`.
public struct Storage: Sendable {
    private let _get: @Sendable (String) async throws -> [UInt8]?
    private let _put: @Sendable (String, [UInt8]) async throws -> Void
    private let _putStream: @Sendable (String, RequestBodyReader) async throws -> Void
    private let _delete: @Sendable (String) async throws -> Void

    public init(_ adapter: some StorageDriver) {
        self._get = { try await adapter.get($0) }
        self._put = { try await adapter.put($0, $1) }
        self._delete = { try await adapter.delete($0) }
        // Fallback for a buffered-only driver: drain the stream, one put. (The
        // Worker's replayed request bodies land here — they were already in memory.)
        self._putStream = { key, reader in
            var bytes: [UInt8] = []
            while let chunk = try await reader.next() { bytes.append(contentsOf: chunk) }
            try await adapter.put(key, bytes)
        }
    }

    /// The overload streaming-capable drivers resolve to (statically, by type).
    public init(_ adapter: some StreamingStorageDriver) {
        self._get = { try await adapter.get($0) }
        self._put = { try await adapter.put($0, $1) }
        self._delete = { try await adapter.delete($0) }
        self._putStream = { try await adapter.put($0, from: $1) }
    }

    public func get(_ key: String) async throws -> [UInt8]? { try await _get(key) }
    public func put(_ key: String, _ bytes: [UInt8]) async throws { try await _put(key, bytes) }
    public func delete(_ key: String) async throws { try await _delete(key) }

    /// Write an object from a chunk stream — the sink for a streaming upload
    /// route, so the payload never sits in memory whole on a capable driver:
    ///
    ///     app.post("/import", body: .streaming) { request in
    ///         guard let reader = request.bodyReader else { return .status(400) }
    ///         try await Storage.current.put("imports/latest.csv", from: reader)
    ///         return .status(201)
    ///     }
    public func put(_ key: String, from reader: RequestBodyReader) async throws {
        try await _putStream(key, reader)
    }

    /// Serve a stored object as an HTTP response, or a 404 if it's missing. Pass the
    /// `contentType` explicitly (there's no extension inference here, so it behaves
    /// identically native and in the wasm guest). Unlike files in `Public/` — static
    /// assets served by the platform — this streams a runtime object (an upload, an
    /// export) straight from object storage, the same way on every target:
    ///
    ///     app.get("/avatars/:id") { request in
    ///         try await Storage.current.serve("avatars/\(request.parameters["id"] ?? "")",
    ///                                         contentType: "image/png")
    ///     }
    public func serve(_ key: String, contentType: String = "application/octet-stream") async throws -> Response {
        guard let bytes = try await get(key) else { return .status(404) }
        var headers = Headers()
        headers.add("content-type", contentType)
        return Response(status: 200, headers: headers, body: bytes)
    }
}
