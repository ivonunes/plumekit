import Foundation
import PlumeCore
import PlumeORM

// Public per-driver factories the generated composition root calls. Each maps a
// plumekit.toml driver name to a concrete native adapter, returning the neutral
// capability handle. Adding a native driver = adding a factory here + a case in
// the CLI's composition codegen.

/// A second native StorageDriver driver (besides filesystem): in-memory. Lets a
/// `plumekit.toml` blob-driver swap be demonstrated with no external infra.
public actor MemoryStorage: StorageDriver {
    private var store: [String: [UInt8]] = [:]
    public init() {}
    public func get(_ key: String) -> [UInt8]? { store[key] }
    public func put(_ key: String, _ bytes: [UInt8]) { store[key] = bytes }
    public func delete(_ key: String) { store[key] = nil }
}

/// A native in-process message queue. The producer binding is `send`; the jobs
/// layer adds a consumer/worker. Messages are held in the actor and drainable for tests.
public actor InProcessQueue: MessageQueue {
    public private(set) var messages: [[UInt8]] = []
    public init() {}
    public func send(_ body: [UInt8]) { messages.append(body) }
    public func drain() -> [[UInt8]] { let m = messages; messages = []; return m }
}

/// The native secrets adapter: reads the process environment. The mirror of
/// Workers secrets/vars on `env`. Reading config from the environment is the
/// 12-factor floor; richer backends (a file, a vault) are additional adapters.
public struct EnvSecrets: SecretStore {
    public init() {}
    public func secret(_ name: String) -> [UInt8]? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        return Array(value.utf8)
    }
}

public enum NativeDrivers {
    // MARK: Database
    public static func sqlite(path: String) throws -> Database {
        .interactiveTransactions(try SQLiteDatabase(path: path), dialect: .sqlite)
    }

    // MARK: Storage
    public static func filesystemStorage(directory: String) -> Storage {
        Storage(FileStorage(directory: directory))
    }
    public static func memoryStorage() -> Storage {
        Storage(MemoryStorage())
    }

    // MARK: Queue
    // The most recently created in-process queue, so the server's job drainer can
    // consume the same instance the request Queue binding produces to. (Dev: one
    // queue per process.)
    nonisolated(unsafe) public static var sharedInProcessQueue: InProcessQueue?
    public static func inProcessQueue() -> Queue {
        let queue = InProcessQueue()
        sharedInProcessQueue = queue
        return Queue(queue)
    }

    // MARK: HTTP client
    public static func httpClient() -> HTTP { HTTP(URLSessionHTTPClient()) }

    // MARK: Secrets
    public static func envSecrets() -> Secrets { Secrets(EnvSecrets()) }

    // MARK: Mailer
    /// Dev default: log the message (see reset/verification links without an SMTP server).
    public static func logMailer() -> Mailer { Mailer(LogMailer()) }
    /// Real SMTP, configured from the environment (SMTP_HOST/PORT/USERNAME/PASSWORD, MAIL_FROM).
    public static func smtpMailer() -> Mailer {
        let env = ProcessInfo.processInfo.environment
        return Mailer(SMTPMailer(
            host: env["SMTP_HOST"] ?? "127.0.0.1",
            port: Int(env["SMTP_PORT"] ?? "1025") ?? 1025,
            username: env["SMTP_USERNAME"],
            password: env["SMTP_PASSWORD"],
            defaultFrom: env["MAIL_FROM"] ?? "no-reply@localhost"
        ))
    }

    // MARK: ORM clock — wall-clock epoch millis for createdAt/updatedAt.
    public static func installNativeClock() {
        ORMClock.now = { Int64(Date().timeIntervalSince1970 * 1000) }
    }

    // MARK: Cache
    /// An in-memory, TTL'd ephemeral cache (the native mirror of a Workers-KV cache).
    public static func memoryCache() -> Cache { Cache(MemoryCache()) }

    // MARK: KV
    public static func fileKV(directory: String) -> KV {
        let store = FileKVStore(directory: directory)
        return KV(
            get: { key in await store.get(key) },
            putExpiring: { key, value, expiresAt in await store.put(key, value, expiresAt: expiresAt) }
        )
    }

    public static let stdoutLog: @Sendable (String) -> Void = { print($0) }
}
