import Testing
@testable import PlumeCore

// PBKDF2-HMAC-SHA256 verified against known RFC-style vectors (password "password",
// salt "salt") so the KDF is proven correct, not just plausible.
@Test func pbkdf2MatchesKnownVectors() {
    let one = pbkdf2SHA256(password: Array("password".utf8), salt: Array("salt".utf8),
                           iterations: 1, keyLength: 32)
    #expect(hexEncode(one) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")

    let two = pbkdf2SHA256(password: Array("password".utf8), salt: Array("salt".utf8),
                           iterations: 2, keyLength: 32)
    #expect(hexEncode(two) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
}

@Test func passwordHasherRoundTripsAndRejects() {
    let hasher = PBKDF2Hasher(iterations: 1000)   // low cost for test speed
    let encoded = hasher.hash("correct horse battery staple")

    #expect(encoded.hasPrefix("pbkdf2-sha256$1000$"))               // self-describing
    #expect(hasher.verify("correct horse battery staple", encoded: encoded))   // accepts
    #expect(!hasher.verify("wrong password", encoded: encoded))                // rejects wrong
    #expect(!hasher.verify("correct horse battery staple", encoded: "garbage")) // rejects malformed

    // Distinct salts → distinct encodings for the same password (no static salt).
    #expect(hasher.hash("same") != hasher.hash("same"))
}
