import Foundation
import Crypto

// AWS Signature Version 4 — a reusable signer extracted from PlumeS3 so the
// SAME signing serves S3, SQS, SSM, DynamoDB, and API Gateway Management. No AWS
// SDK; SHA256 + HMAC via swift-crypto. Native only (the AWS target is a native
// binary). Verified offline against AWS's published aws4 test vectors.

public struct SigV4: Sendable {
    public let region: String
    public let service: String
    public let accessKey: String
    public let secretKey: String

    public init(region: String, service: String, accessKey: String, secretKey: String) {
        self.region = region
        self.service = service
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    /// Produce the `Authorization` header for a request. `headers` are the headers to
    /// SIGN (must include `host`); names are lowercased + the set sorted internally.
    /// `payloadHash` is hex(SHA256(body)). `amzDate` is `yyyyMMdd'T'HHmmss'Z'`,
    /// `dateStamp` its `yyyyMMdd` prefix.
    public func authorization(
        method: String,
        canonicalURI: String,
        canonicalQuery: String,
        headers: [(name: String, value: String)],
        payloadHash: String,
        amzDate: String,
        dateStamp: String
    ) -> String {
        let lowered = headers
            .map { (name: $0.name.lowercased(), value: $0.value) }
            .sorted { $0.name < $1.name }
        let canonicalHeaders = lowered.map { "\($0.name):\($0.value)\n" }.joined()
        let signedHeaders = lowered.map { $0.name }.joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")

        let key = Self.signingKey(secret: secretKey, date: dateStamp, region: region, service: service)
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    // MARK: - Helpers (shared)

    public static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let table = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in digest { out.append(table[Int(b >> 4)]); out.append(table[Int(b & 0xf)]) }
        return String(decoding: out, as: UTF8.self)
    }

    public static func payloadHash(_ body: Data) -> String { hex(SHA256.hash(data: body)) }

    public static func timestamps(_ now: Date = Date()) -> (amzDate: String, dateStamp: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = f.string(from: now)
        f.dateFormat = "yyyyMMdd"
        return (amz, f.string(from: now))
    }

    static func signingKey(secret: String, date: String, region: String, service: String) -> SymmetricKey {
        func mac(_ key: SymmetricKey, _ msg: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: key)))
        }
        let kDate = mac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), date)
        let kRegion = mac(kDate, region)
        let kService = mac(kRegion, service)
        return mac(kService, "aws4_request")
    }
}
