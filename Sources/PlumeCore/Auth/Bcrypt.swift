import _Concurrency

// bcrypt password hashing — an Embedded-clean `PasswordHasher` that verifies (and
// mints) `$2a$`/`$2b$`/`$2y$` hashes. PlumeKit's default is PBKDF2 (secure by construction on
// the verified hmacSHA256); bcrypt is provided for ADOPTING an existing app whose stored
// hashes are bcrypt — including on the Cloudflare wasm guest, where a "native only" bcrypt
// swap doesn't reach. Pure integer/byte math (Blowfish + EksBlowfish + bcrypt-base64), no
// Foundation; the constants live in BcryptTables.swift. Algorithm follows jBCrypt exactly
// (the reference bcryptjs ports), so hashes interoperate byte-for-byte.

// MARK: - Blowfish state

private struct BlowfishState {
    var p: [UInt32]
    var s: [UInt32]
    init() { p = bcryptInitP; s = bcryptInitS }

    @inline(__always) func f(_ x: UInt32) -> UInt32 {
        let a = Int(x >> 24)
        let b = Int((x >> 16) & 0xff)
        let c = Int((x >> 8) & 0xff)
        let d = Int(x & 0xff)
        return ((s[a] &+ s[256 + b]) ^ s[512 + c]) &+ s[768 + d]
    }

    /// Encipher a 64-bit block (jBCrypt's unrolled Feistel network).
    @inline(__always) func encipher(_ l0: UInt32, _ r0: UInt32) -> (UInt32, UInt32) {
        var l = l0 ^ p[0]
        var r = r0
        var i = 0
        while i <= 14 {
            r ^= f(l) ^ p[i + 1]; i += 1
            l ^= f(r) ^ p[i + 1]; i += 1
        }
        return (r ^ p[17], l)
    }

    /// Blowfish key schedule. `data` non-nil = EksBlowfish "expandstate" (salt XOR'd into the
    /// running block); nil = "expand0state" (encrypt zeros). Key/data streamed cyclically.
    mutating func expandKey(data: [UInt8]?, key: [UInt8]) {
        var koff = 0
        for i in 0..<18 { p[i] ^= streamToWord(key, &koff) }
        var doff = 0
        var l: UInt32 = 0
        var r: UInt32 = 0
        var i = 0
        while i < 18 {
            if let data { l ^= streamToWord(data, &doff); r ^= streamToWord(data, &doff) }
            (l, r) = encipher(l, r)
            p[i] = l; p[i + 1] = r
            i += 2
        }
        i = 0
        while i < 1024 {
            if let data { l ^= streamToWord(data, &doff); r ^= streamToWord(data, &doff) }
            (l, r) = encipher(l, r)
            s[i] = l; s[i + 1] = r
            i += 2
        }
    }
}

/// Read 4 bytes (big-endian) from `data` starting at `off`, cycling; advance `off`.
private func streamToWord(_ data: [UInt8], _ off: inout Int) -> UInt32 {
    var word: UInt32 = 0
    for _ in 0..<4 {
        word = (word << 8) | UInt32(data[off])
        off = (off + 1) % data.count
    }
    return word
}

// MARK: - bcrypt core

private let bcryptMagic: [UInt32] = [
    0x4f72_7068, 0x6561_6e42, 0x6568_6f6c, 0x6465_7253, 0x6372_7944, 0x6f75_6274,
]  // "OrpheanBeholderScryDoubt"

/// The 23-byte bcrypt output for a password + 16-byte salt at the given cost.
private func bcryptRaw(password: [UInt8], salt: [UInt8], cost: Int) -> [UInt8] {
    var state = BlowfishState()
    state.expandKey(data: salt, key: password)
    let rounds = 1 << cost
    var k = 0
    while k < rounds {
        state.expandKey(data: nil, key: password)
        state.expandKey(data: nil, key: salt)
        k += 1
    }
    var cdata = bcryptMagic
    for _ in 0..<64 {
        var j = 0
        while j < 6 {
            let (a, b) = state.encipher(cdata[j], cdata[j + 1])
            cdata[j] = a; cdata[j + 1] = b
            j += 2
        }
    }
    // 6 words → 24 bytes, big-endian; bcrypt uses the first 23.
    var out: [UInt8] = []
    out.reserveCapacity(24)
    for w in cdata {
        out.append(UInt8((w >> 24) & 0xff))
        out.append(UInt8((w >> 16) & 0xff))
        out.append(UInt8((w >> 8) & 0xff))
        out.append(UInt8(w & 0xff))
    }
    return Array(out[0..<23])
}

/// The password key material: UTF-8 bytes + a trailing NUL (the `$2b`/`$2a` convention).
private func bcryptKey(_ password: String) -> [UInt8] { Array(password.utf8) + [0] }

// MARK: - bcrypt base64 (its own alphabet, not standard base64)

private let bcryptAlphabet: [UInt8] =
    Array("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)

private func bcryptBase64Encode(_ d: [UInt8], _ len: Int) -> [UInt8] {
    var out: [UInt8] = []
    var off = 0
    while off < len {
        var c1 = Int(d[off]); off += 1
        out.append(bcryptAlphabet[(c1 >> 2) & 0x3f])
        c1 = (c1 & 0x03) << 4
        if off >= len { out.append(bcryptAlphabet[c1 & 0x3f]); break }
        var c2 = Int(d[off]); off += 1
        c1 |= (c2 >> 4) & 0x0f
        out.append(bcryptAlphabet[c1 & 0x3f])
        c1 = (c2 & 0x0f) << 2
        if off >= len { out.append(bcryptAlphabet[c1 & 0x3f]); break }
        c2 = Int(d[off]); off += 1
        c1 |= (c2 >> 6) & 0x03
        out.append(bcryptAlphabet[c1 & 0x3f])
        out.append(bcryptAlphabet[c2 & 0x3f])
    }
    return out
}

private func bcryptChar64(_ c: UInt8) -> Int {
    if c == 0x2e { return 0 }                              // '.'
    if c == 0x2f { return 1 }                              // '/'
    if c >= 0x41 && c <= 0x5a { return Int(c - 0x41) + 2 }  // A-Z
    if c >= 0x61 && c <= 0x7a { return Int(c - 0x61) + 28 } // a-z
    if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) + 54 } // 0-9
    return -1
}

private func bcryptBase64Decode(_ s: [UInt8], _ maxLen: Int) -> [UInt8]? {
    var out: [UInt8] = []
    var off = 0
    let slen = s.count
    while off < slen - 1 && out.count < maxLen {
        let c1 = bcryptChar64(s[off]); off += 1
        let c2 = bcryptChar64(s[off]); off += 1
        if c1 == -1 || c2 == -1 { break }
        out.append(UInt8(((c1 << 2) | ((c2 & 0x30) >> 4)) & 0xff))
        if out.count >= maxLen || off >= slen { break }
        let c3 = bcryptChar64(s[off]); off += 1
        if c3 == -1 { break }
        out.append(UInt8((((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2)) & 0xff))
        if out.count >= maxLen || off >= slen { break }
        let c4 = bcryptChar64(s[off]); off += 1
        if c4 == -1 { break }
        out.append(UInt8((((c3 & 0x03) << 6) | c4) & 0xff))
    }
    return out.count == maxLen ? out : nil
}

private struct ParsedBcrypt { let cost: Int; let salt: [UInt8]; let hash: [UInt8] }

/// Parse `$2[aby]$<cost>$<22-char salt><31-char hash>`.
private func parseBcrypt(_ encoded: String) -> ParsedBcrypt? {
    let parts = splitOnByte(Array(encoded.utf8), 0x24)   // '$' → ["", "2b", "10", saltAndHash]
    guard parts.count == 4 else { return nil }
    let minor = parts[1]
    guard minor.count == 2, minor[0] == 0x32 else { return nil }        // '2'
    guard minor[1] == 0x61 || minor[1] == 0x62 || minor[1] == 0x79 else { return nil }  // a/b/y
    guard let cost = Int(decodeUTF8(parts[2])), cost >= 4, cost <= 31 else { return nil }
    let saltAndHash = parts[3]
    guard saltAndHash.count == 53 else { return nil }                    // 22 + 31
    return ParsedBcrypt(cost: cost, salt: Array(saltAndHash[0..<22]), hash: Array(saltAndHash[22..<53]))
}

// MARK: - Hashers

/// A `PasswordHasher` that hashes and verifies bcrypt (`$2b$`). Use it to adopt an app whose
/// stored password hashes are bcrypt; new hashes are bcrypt too (interoperable with other
/// bcrypt stacks writing the same table).
public struct BcryptHasher: PasswordHasher {
    public let cost: Int
    private let randomSalt: @Sendable (Int) -> [UInt8]

    public init(cost: Int = 10, randomSalt: @escaping @Sendable (Int) -> [UInt8] = PBKDF2Hasher.secureRandom) {
        self.cost = cost
        self.randomSalt = randomSalt
    }

    public func hash(_ password: String) -> String {
        let salt = randomSalt(16)
        let raw = bcryptRaw(password: bcryptKey(password), salt: salt, cost: cost)
        let costStr = cost < 10 ? "0" + String(cost) : String(cost)
        return "$2b$" + costStr + "$"
            + decodeUTF8(bcryptBase64Encode(salt, 16))
            + decodeUTF8(bcryptBase64Encode(raw, 23))
    }

    public func verify(_ password: String, encoded: String) -> Bool {
        guard let parsed = parseBcrypt(encoded),
              let salt = bcryptBase64Decode(parsed.salt, 16) else { return false }
        let raw = bcryptRaw(password: bcryptKey(password), salt: salt, cost: parsed.cost)
        return constantTimeEqual(bcryptBase64Encode(raw, 23), parsed.hash)   // timing-safe
    }
}

/// A `PasswordHasher` for GRADUAL migration off bcrypt: verifies existing bcrypt hashes but
/// mints new ones with PBKDF2 (so passwords upgrade to the framework default whenever they're
/// re-hashed — e.g. after a password reset). Non-bcrypt encodings fall through to PBKDF2.
public struct MigrationHasher: PasswordHasher {
    private let bcrypt: BcryptHasher
    private let pbkdf2: PBKDF2Hasher

    public init(bcrypt: BcryptHasher = BcryptHasher(), pbkdf2: PBKDF2Hasher = PBKDF2Hasher()) {
        self.bcrypt = bcrypt
        self.pbkdf2 = pbkdf2
    }

    public func hash(_ password: String) -> String { pbkdf2.hash(password) }

    public func verify(_ password: String, encoded: String) -> Bool {
        let bytes = Array(encoded.utf8)
        if bytes.count >= 2 && bytes[0] == 0x24 && bytes[1] == 0x32 {   // "$2"
            return bcrypt.verify(password, encoded: encoded)
        }
        return pbkdf2.verify(password, encoded: encoded)
    }
}
