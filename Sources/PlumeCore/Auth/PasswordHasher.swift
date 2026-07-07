import _Concurrency

// Password hashing — secure by default, with NO path to plaintext.
//
// The default is PBKDF2-HMAC-SHA256: correct BY CONSTRUCTION on the already-verified
// `hmacSHA256`, and Embedded-clean (the Cloudflare guest runs register/login, and a
// hand-rolled Argon2/bcrypt in the shared wasm core is a large correctness risk for
// a security primitive). `PasswordHasher` is a protocol so a deployment can swap in
// Argon2id/bcrypt natively — the recommended production hasher — WITHOUT touching
// sessions or authorization. 600k iterations meets OWASP guidance
// for PBKDF2-HMAC-SHA256.
//
// Encoded format (self-describing, ASCII, byte-wise parseable):
//   pbkdf2-sha256$<iterations>$<saltHex>$<hashHex>

/// What an authentication method uses to store + check passwords. Implementations
/// MUST never expose or store plaintext, and MUST verify in constant time.
public protocol PasswordHasher: Sendable {
    /// Hash a password into a self-describing encoded string (with a fresh salt).
    func hash(_ password: String) -> String
    /// Constant-time verify of `password` against a previously-encoded hash.
    func verify(_ password: String, encoded: String) -> Bool
}

public struct PBKDF2Hasher: PasswordHasher {
    public let iterations: Int
    public let saltLength: Int
    public let keyLength: Int
    private let randomSalt: @Sendable (Int) -> [UInt8]

    public init(
        iterations: Int = 600_000,
        saltLength: Int = 16,
        keyLength: Int = 32,
        randomSalt: @escaping @Sendable (Int) -> [UInt8] = PBKDF2Hasher.secureRandom
    ) {
        self.iterations = iterations
        self.saltLength = saltLength
        self.keyLength = keyLength
        self.randomSalt = randomSalt
    }

    public func hash(_ password: String) -> String {
        let salt = randomSalt(saltLength)
        let derived = pbkdf2SHA256(password: Array(password.utf8), salt: salt,
                                   iterations: iterations, keyLength: keyLength)
        return "pbkdf2-sha256$" + String(iterations) + "$" + hexEncode(salt) + "$" + hexEncode(derived)
    }

    public func verify(_ password: String, encoded: String) -> Bool {
        let parts = splitOnByte(Array(encoded.utf8), 0x24)   // '$'
        guard parts.count == 4, parts[0] == Array("pbkdf2-sha256".utf8) else { return false }
        guard let iters = Int(decodeUTF8(parts[1])), iters > 0 else { return false }
        guard let salt = hexDecode(parts[2]), let expected = hexDecode(parts[3]), !expected.isEmpty else {
            return false
        }
        let derived = pbkdf2SHA256(password: Array(password.utf8), salt: salt,
                                   iterations: iters, keyLength: expected.count)
        return constantTimeEqual(derived, expected)   // timing-safe
    }

    /// Cryptographically secure salt. `SystemRandomNumberGenerator` maps to the OS
    /// RNG natively and to WASI `random_get` in the wasm guest.
    public static let secureRandom: @Sendable (Int) -> [UInt8] = { count in
        var rng = SystemRandomNumberGenerator()
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }
        return out
    }
}
