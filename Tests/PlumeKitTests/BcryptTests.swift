import Testing
@testable import PlumeCore

// bcrypt interop: verify against hashes minted by the reference implementation (jBCrypt /
// bcryptjs). Each `verify` re-derives the hash from the password + the salt/cost embedded in
// the encoded string and compares to the stored 31-char hash, so passing proves the Blowfish +
// EksBlowfish + bcrypt-base64 pipeline is byte-exact with the reference.

@Test func bcryptVerifiesReferenceVectors() {
    let h = BcryptHasher()
    let vectors: [(String, String)] = [
        ("password123", "$2b$10$rzFp5e0shP4vILspPcK5Kea/fCl25CowyCi4zIFWhRX4HS1Yb782q"),
        ("", "$2b$10$UsJ4w6SmZy41YlPcdC3Df.DVCbfhRRVAjIp34AWin2DuEMyBCWfeC"),
        ("a", "$2b$10$bTdDWr/7eZb5TDWFKR4D6OI3M5i9wqw8/e2z74wHagTNdDqavDoFi"),
        ("correct horse battery staple", "$2b$10$44HE0OFQaxiZ7iWjPafTMu21SBXgMdAczPXIgogQsZJki7FoRWhwW"),
        ("hello-world", "$2b$10$CFivLa7DE4tHTRWcotBMdOPlpjwXpaCRqZ51eQYFvGHPeJIl4zkC2"),
    ]
    for (password, hash) in vectors {
        #expect(h.verify(password, encoded: hash), "should verify: \(password)")
        #expect(!h.verify(password + "x", encoded: hash), "should reject wrong password: \(password)")
    }
    // A malformed / non-bcrypt encoding never verifies.
    #expect(!h.verify("x", encoded: "not-a-hash"))
    #expect(!h.verify("x", encoded: "$2b$10$short"))
}

@Test func bcryptHashRoundTripsWithFreshSaltEachTime() {
    let h = BcryptHasher()
    let a = h.hash("s3cret-pass")
    let b = h.hash("s3cret-pass")
    #expect(a != b)                                  // random salt → distinct encodings
    #expect(a.count == 60 && a.hasPrefix("$2b$10$")) // $2b$10$ + 22 salt + 31 hash
    #expect(h.verify("s3cret-pass", encoded: a))
    #expect(h.verify("s3cret-pass", encoded: b))
    #expect(!h.verify("wrong", encoded: a))
}

// The gradual-migration hasher: verify legacy bcrypt, mint new PBKDF2.
@Test func migrationHasherVerifiesBcryptMintsPBKDF2() {
    let m = MigrationHasher()
    #expect(m.verify("password123", encoded: "$2b$10$rzFp5e0shP4vILspPcK5Kea/fCl25CowyCi4zIFWhRX4HS1Yb782q"))
    let fresh = m.hash("password123")
    #expect(fresh.hasPrefix("pbkdf2-sha256$"))
    #expect(m.verify("password123", encoded: fresh))
    #expect(!m.verify("wrong", encoded: fresh))
}
