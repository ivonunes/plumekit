// A signed session/bearer token — the wire credential carried by both the
// cookie session and the Authorization: Bearer header. HMAC-SHA256 over the signing
// secret (SecretProvider). Byte-wise throughout so it verifies
// in the embedded guest.
//
// Wire: hex(subject) "." jti "." expirySeconds "." hex(hmac)
//   signed message = subject 0x1F jti 0x1F expirySeconds   (0x1F = unit separator)
// `jti` is the session id (random hex), used for revocation. The secret never
// crosses the wire; a client treats the whole string as opaque.
public enum SessionToken {
    static func signedMessage(_ subject: String, _ jti: String, _ expiry: Int) -> [UInt8] {
        var message = Array(subject.utf8)
        message.append(0x1F)
        message.append(contentsOf: Array(jti.utf8))
        message.append(0x1F)
        message.append(contentsOf: Array(String(expiry).utf8))
        return message
    }

    public static func mint(subject: String, jti: String, expiresAt: Int, key: [UInt8]) -> String {
        let sig = hmacSHA256(key: key, message: signedMessage(subject, jti, expiresAt))
        return hexEncode(Array(subject.utf8)) + "." + jti + "." + String(expiresAt) + "." + hexEncode(sig)
    }

    /// Returns (subject, jti) if the signature is valid and the token is unexpired.
    public static func verify(_ token: String, now: Int, key: [UInt8]) -> (subject: String, jti: String)? {
        let parts = splitOnByte(Array(token.utf8), 0x2E)   // '.'
        guard parts.count == 4 else { return nil }
        guard let subjectBytes = hexDecode(parts[0]) else { return nil }
        let jti = decodeUTF8(parts[1])
        guard let expiry = Int(decodeUTF8(parts[2])) else { return nil }
        guard let sig = hexDecode(parts[3]) else { return nil }
        if now > expiry { return nil }
        let subject = decodeUTF8(subjectBytes)
        let expected = hmacSHA256(key: key, message: signedMessage(subject, jti, expiry))
        guard constantTimeEqual(sig, expected) else { return nil }   // timing-safe
        return (subject, jti)
    }
}
