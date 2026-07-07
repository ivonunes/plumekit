import _Concurrency

// Sessions: issue / resolve / revoke a signed session, independent of HOW it's
// carried (cookie vs bearer — see Identity.swift) and of HOW you authenticated
// (password vs anything else). Swapping the store must not touch authentication.
//
// Revocation model: tokens are signed + self-describing (stateless happy path); a
// REVOKED session id is recorded in a denylist store and checked on resolve. So
// logout/revocation works with only get+put (the KV capability) — no delete needed.
// The entry is written with the token's own expiry, so it self-evicts exactly when
// the token would have expired (the denylist can't grow without bound).

/// The revocation store behind sessions — a key/value capability (KV, a cache, …).
public protocol SessionStore: Sendable {
    func isRevoked(_ sessionID: String) async -> Bool
    func revoke(_ sessionID: String, until expiresAt: Int) async
}

/// KV-backed default session store. Swap it for any `SessionStore` without touching
/// authentication or authorization.
public struct KVSessionStore: SessionStore {
    let kv: KV
    public init(_ kv: KV) { self.kv = kv }
    public func isRevoked(_ sessionID: String) async -> Bool {
        await kv.get("plumekit:revoked:" + sessionID) != nil
    }
    public func revoke(_ sessionID: String, until expiresAt: Int) async {
        // Expire the denylist entry when the token itself expires — after that a
        // still-presented token fails the signature/expiry check anyway.
        await kv.put("plumekit:revoked:" + sessionID, [1], expiresAt: expiresAt)
    }
}

public struct SessionManager: Sendable {
    let key: [UInt8]
    let ttlSeconds: Int
    let now: @Sendable () -> Int                 // epoch seconds
    let randomID: @Sendable () -> String
    private let _isRevoked: @Sendable (String) async -> Bool
    private let _revoke: @Sendable (String, Int) async -> Void

    public init(
        key: [UInt8],
        store: some SessionStore,
        ttlSeconds: Int = 60 * 60 * 24 * 7,
        now: @escaping @Sendable () -> Int,
        randomID: @escaping @Sendable () -> String = SessionManager.randomToken
    ) {
        self.key = key
        self.ttlSeconds = ttlSeconds
        self.now = now
        self.randomID = randomID
        self._isRevoked = { await store.isRevoked($0) }   // store wrapped in closures (no stored existential)
        self._revoke = { await store.revoke($0, until: $1) }
    }

    /// Issue a fresh signed session token for `subject`.
    public func issue(subject: String) -> String {
        SessionToken.mint(subject: subject, jti: randomID(), expiresAt: now() + ttlSeconds, key: key)
    }

    /// Resolve a token to a `Principal`, or nil (bad signature / expired / revoked).
    public func resolve(_ token: String) async -> Principal? {
        guard let (subject, jti) = SessionToken.verify(token, now: now(), key: key) else { return nil }
        if await _isRevoked(jti) { return nil }
        return Principal(subject: subject, sessionID: jti)
    }

    /// Revoke the session a token names (logout / forced sign-out).
    public func revoke(_ token: String) async {
        guard let (_, jti) = SessionToken.verify(token, now: now(), key: key) else { return }
        await _revoke(jti, now() + ttlSeconds)
    }

    /// 16 random bytes, hex. OS RNG natively / WASI `random_get` in the guest.
    public static let randomToken: @Sendable () -> String = {
        var rng = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        for _ in 0..<16 { bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }
        return hexEncode(bytes)
    }
}
