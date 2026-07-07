import _Concurrency

// Authentication — proving WHO you are, separate from sessions (how identity is
// carried) and authorization (what you may do). Email+password is the only built-in
// method; OAuth/magic-link/passkey/2FA conform the same `Authentication` seam later.
// Swapping the method must not touch sessions or policies, so the
// authenticator deals only in a subject id — never the app's User type or a session.

/// The outcome of a registration attempt. Returned (not thrown): embedded Swift
/// forbids `any Error`, so — like validation — we surface the outcome as a value.
public enum RegisterOutcome: Sendable {
    case created(subject: String)
    case emailTaken
}

/// Marker seam: every authentication method (password, OAuth, …) conforms this so an
/// app can swap the method without touching the rest of the stack.
public protocol Authentication: Sendable {}

/// Where password credentials live. Default: SQL (`SQLCredentialStore`); swap it for
/// any backend without touching the authenticator. Returns/keys on a subject id.
public protocol CredentialStore: Sendable {
    func ensureTable() async throws
    func findCredential(email: String) async throws -> (subject: String, passwordHash: String)?
    func createCredential(email: String, passwordHash: String) async throws -> String
}

/// SQL-backed credential store over the neutral `Database` (dialect-aware, so it works on
/// SQLite/D1 and Postgres). The password hash is stored; plaintext never is.
public struct SQLCredentialStore: CredentialStore {
    let db: Database
    public init(_ db: Database) { self.db = db }

    public func ensureTable() async throws {
        let idColumn = db.dialect == .postgres
            ? "id BIGSERIAL PRIMARY KEY"
            : "id INTEGER PRIMARY KEY AUTOINCREMENT"
        _ = try await db.query(
            "CREATE TABLE IF NOT EXISTS auth_credentials (" + idColumn
            + ", email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL)", [])
    }

    public func findCredential(email: String) async throws -> (subject: String, passwordHash: String)? {
        let result = try await db.query(
            "SELECT id, password_hash FROM auth_credentials WHERE email = ?", [.text(email)])
        guard let row = result.rows.first, row.count >= 2 else { return nil }
        let subject: String
        switch row[0] {
        case .integer(let n): subject = String(n)
        case .text(let s): subject = s
        default: return nil
        }
        guard case .text(let hash) = row[1] else { return nil }
        return (subject, hash)
    }

    public func createCredential(email: String, passwordHash: String) async throws -> String {
        let sql = "INSERT INTO auth_credentials (email, password_hash) VALUES (?, ?)"
        switch db.dialect {
        case .postgres:
            let result = try await db.query(sql + " RETURNING id", [.text(email), .text(passwordHash)])
            if case .integer(let n)? = result.rows.first?.first { return String(n) }
            return ""
        case .sqlite:
            let result = try await db.query(sql, [.text(email), .text(passwordHash)])
            return String(result.lastInsertID)
        }
    }
}

/// The built-in email+password method. Hashing + storage are injected (and
/// swappable); plaintext is never stored or returned.
public struct PasswordAuthenticator: Authentication {
    private let _hash: @Sendable (String) -> String
    private let _verify: @Sendable (String, String) -> Bool
    private let _find: @Sendable (String) async throws -> (subject: String, passwordHash: String)?
    private let _create: @Sendable (String, String) async throws -> String
    private let _ensure: @Sendable () async throws -> Void

    public init(hasher: some PasswordHasher, store: some CredentialStore) {
        self._hash = { hasher.hash($0) }
        self._verify = { hasher.verify($0, encoded: $1) }
        self._find = { try await store.findCredential(email: $0) }
        self._create = { try await store.createCredential(email: $0, passwordHash: $1) }
        self._ensure = { try await store.ensureTable() }
    }

    public func ensureReady() async throws { try await _ensure() }

    /// Register a new credential, or `.emailTaken` if one already exists.
    public func register(email: String, password: String) async throws -> RegisterOutcome {
        if try await _find(email) != nil { return .emailTaken }
        return .created(subject: try await _create(email, _hash(password)))
    }

    /// Verify credentials → subject id, or nil. On unknown email it still runs ONE
    /// hash at the configured cost (discarded) so login timing doesn't reveal which
    /// emails exist — equalized to the hasher's own cost, not a hardcoded one.
    public func authenticate(email: String, password: String) async throws -> String? {
        guard let credential = try await _find(email) else {
            _ = _hash(password)   // timing equalization at the configured cost
            return nil
        }
        return _verify(password, credential.passwordHash) ? credential.subject : nil
    }
}
