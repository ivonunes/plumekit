import _Concurrency

// MARK: - The Secrets capability
//
// Configuration & secrets as a portable concept: a handler asks for a named
// secret and gets its bytes (or nil). It NEVER reads `env` directly and never
// names a platform primitive. Adapters: Cloudflare (secrets/vars on the Worker
// `env`, via the host bridge) and native (process environment variables).
//
// Secrets are runtime config — never compiled in. `async` because a backend may
// be remote (a vault / secret manager); the env-backed adapters just return
// without suspending.

/// What a secret-store adapter implements. Values are opaque `[UInt8]`; `nil`
/// means "no such secret".
public protocol SecretStore: Sendable {
    func secret(_ name: String) async throws -> [UInt8]?
}

/// The Embedded-clean secrets handle carried in `Context`.
public struct Secrets: Sendable {
    private let _secret: @Sendable (String) async throws -> [UInt8]?

    public init(_ adapter: some SecretStore) {
        self._secret = { try await adapter.secret($0) }
    }
    public init(secret: @escaping @Sendable (String) async throws -> [UInt8]?) {
        self._secret = secret
    }

    /// The raw bytes of the secret named `name`, or nil if it is not set.
    public func secret(_ name: String) async throws -> [UInt8]? {
        try await _secret(name)
    }

    /// The UTF-8-decoded secret named `name`, or nil if it is not set.
    public func secretString(_ name: String) async throws -> String? {
        guard let bytes = try await _secret(name) else { return nil }
        return decodeUTF8(bytes)
    }

    /// Whether a secret named `name` is set (without exposing its value).
    public func has(_ name: String) async throws -> Bool {
        try await _secret(name) != nil
    }
}
