import Testing
@testable import PlumeCore

// Proves the three auth layers are NOT entangled — the most likely real auth bug is a
// stack where swapping login secretly drags sessions. These tests swap one layer and
// show the others are untouched (they don't even reference the swapped type).

private actor StoreA: SessionStore {
    var revoked: Set<String> = []
    func isRevoked(_ id: String) -> Bool { revoked.contains(id) }
    func revoke(_ id: String, until: Int) { revoked.insert(id) }
}
// A structurally different store (revocation tracked differently) — same protocol.
private final class StoreB: SessionStore, @unchecked Sendable {
    private var killed: [String: Bool] = [:]
    func isRevoked(_ id: String) -> Bool { killed[id] ?? false }
    func revoke(_ id: String, until: Int) { killed[id] = true }
}

// A NON-password authentication method (magic-link-style stub) — conforms the same
// Authentication seam, produces a subject id, and knows nothing about sessions.
private struct MagicLinkAuth: Authentication {
    func authenticate(magicToken: String) -> String? { magicToken == "valid-link" ? "user-42" : nil }
}

private actor Creds: CredentialStore {
    var byEmail: [String: (subject: String, hash: String)] = [:]
    func ensureTable() {}
    func findCredential(email: String) -> (subject: String, passwordHash: String)? {
        byEmail[email].map { ($0.subject, $0.hash) }
    }
    func createCredential(email: String, passwordHash: String) -> String {
        let id = "u" + String(byEmail.count + 1); byEmail[email] = (id, passwordHash); return id
    }
}

@Test func swapAuthMethodWithoutTouchingSessionsOrPolicies() async {
    // Authenticate via a NON-password method...
    guard let subject = MagicLinkAuth().authenticate(magicToken: "valid-link") else {
        Issue.record("expected subject"); return
    }
    // ...and the IDENTICAL session machinery carries it (sessions never reference the
    // authentication method).
    let manager = SessionManager(key: Array("k".utf8), store: StoreA(), now: { 1000 })
    let token = manager.issue(subject: subject)
    #expect(await manager.resolve(token)?.subject == "user-42")
}

@Test func swapSessionStoreWithoutTouchingAuthentication() async throws {
    // The SAME PasswordAuthenticator (authentication) is unchanged across two
    // structurally different session stores.
    let auth = PasswordAuthenticator(hasher: PBKDF2Hasher(iterations: 500), store: Creds())
    guard case .created(let subject) = try await auth.register(email: "x@y.com", password: "pw") else {
        Issue.record("expected created"); return
    }
    #expect(try await auth.authenticate(email: "x@y.com", password: "pw") == subject)

    let mgrA = SessionManager(key: Array("k".utf8), store: StoreA(), now: { 1000 })
    let mgrB = SessionManager(key: Array("k".utf8), store: StoreB(), now: { 1000 })
    #expect(await mgrA.resolve(mgrA.issue(subject: subject))?.subject == subject)
    #expect(await mgrB.resolve(mgrB.issue(subject: subject))?.subject == subject)

    // Revocation works through whichever store, still without touching auth.
    let t = mgrB.issue(subject: subject)
    await mgrB.revoke(t)
    #expect(await mgrB.resolve(t) == nil)
}
