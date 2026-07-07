import Testing
@testable import PlumeCore

private actor MemCredStore: CredentialStore {
    var byEmail: [String: (subject: String, hash: String)] = [:]
    var nextID = 1
    func ensureTable() {}
    func findCredential(email: String) -> (subject: String, passwordHash: String)? {
        guard let c = byEmail[email] else { return nil }
        return (c.subject, c.hash)
    }
    func createCredential(email: String, passwordHash: String) -> String {
        let id = String(nextID); nextID += 1
        byEmail[email] = (id, passwordHash)
        return id
    }
    func storedHash(_ email: String) -> String? { byEmail[email]?.hash }
}

@Test func registerLoginRejectAndNeverPlaintext() async throws {
    let store = MemCredStore()
    let auth = PasswordAuthenticator(hasher: PBKDF2Hasher(iterations: 1000), store: store)

    guard case .created(let subject) = try await auth.register(email: "a@b.com", password: "hunter2") else {
        Issue.record("expected created"); return
    }
    #expect(!subject.isEmpty)

    // Plaintext is never stored — only the PBKDF2 hash.
    let stored = await store.storedHash("a@b.com")
    #expect(stored != nil)
    #expect(!(stored ?? "").contains("hunter2"))
    #expect((stored ?? "").hasPrefix("pbkdf2-sha256$"))

    #expect(try await auth.authenticate(email: "a@b.com", password: "hunter2") == subject)  // login
    #expect(try await auth.authenticate(email: "a@b.com", password: "wrong") == nil)         // wrong pw
    #expect(try await auth.authenticate(email: "ghost@b.com", password: "x") == nil)         // unknown user

    guard case .emailTaken = try await auth.register(email: "a@b.com", password: "y") else {
        Issue.record("expected emailTaken"); return                                          // duplicate
    }
}
