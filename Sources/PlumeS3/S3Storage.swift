import Foundation
import Crypto
import PlumeCore
import PlumeAWS  // shared SigV4 — the signer generalizes beyond S3

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif

// S3-compatible StorageDriver (works against AWS S3, MinIO, R2's S3 API, …). Speaks
// the S3 REST API over HTTPS with AWS Signature V4 — proving the StorageDriver
// abstraction takes a network/object-store driver, not just a local one.
//
// Path-style addressing (endpoint/bucket/key), GET/PUT/DELETE. SigV4 is
// implemented here (SHA256 + HMAC via swift-crypto); no AWS SDK dependency.

public enum S3Error: Error, CustomStringConvertible {
    case badEndpoint(String), http(Int, String)
    public var description: String {
        switch self {
        case .badEndpoint(let e): return "s3 bad endpoint: \(e)"
        case .http(let code, let body): return "s3 http \(code): \(body)"
        }
    }
}

public struct S3Storage: StorageDriver {
    let endpoint: String       // e.g. http://127.0.0.1:9000
    let region: String         // e.g. us-east-1
    let bucket: String
    let accessKey: String
    let secretKey: String

    public init(endpoint: String, region: String, bucket: String, accessKey: String, secretKey: String) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    public func get(_ key: String) async throws -> [UInt8]? {
        let (data, status) = try await send("GET", key: key, body: nil)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw S3Error.http(status, String(decoding: data, as: UTF8.self)) }
        return [UInt8](data)
    }

    public func put(_ key: String, _ bytes: [UInt8]) async throws {
        let (data, status) = try await send("PUT", key: key, body: Data(bytes))
        guard (200..<300).contains(status) else { throw S3Error.http(status, String(decoding: data, as: UTF8.self)) }
    }

    public func delete(_ key: String) async throws {
        let (data, status) = try await send("DELETE", key: key, body: nil)
        guard (200..<300).contains(status) || status == 404 else {
            throw S3Error.http(status, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Signed request

    private func send(_ method: String, key: String, body: Data?) async throws -> (Data, Int) {
        guard let base = URL(string: endpoint) else { throw S3Error.badEndpoint(endpoint) }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? key
        let canonicalURI = "/\(bucket)/\(encodedKey)"
        guard let url = URL(string: endpoint + canonicalURI) else { throw S3Error.badEndpoint(endpoint) }
        let host = base.host! + (base.port.map { ":\($0)" } ?? "")

        let payload = body ?? Data()
        let payloadHash = SigV4.payloadHash(payload)
        let (amzDate, dateStamp) = SigV4.timestamps()

        let signer = SigV4(region: region, service: "s3", accessKey: accessKey, secretKey: secretKey)
        let authorization = signer.authorization(
            method: method, canonicalURI: canonicalURI, canonicalQuery: "",
            headers: [("host", host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", amzDate)],
            payloadHash: payloadHash, amzDate: amzDate, dateStamp: dateStamp)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    /// Unreserved path characters per RFC 3986 (S3 keys; `/` left to the caller).
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")   // keep `/` literal so "a/b.jpg" stays a path, not "a%2Fb.jpg"
        return set
    }()
}

/// Factory the generated composition root calls when `storage = "s3"`.
public enum S3Driver {
    public static func connect(
        endpoint: String, region: String, bucket: String, accessKey: String, secretKey: String
    ) -> Storage {
        Storage(S3Storage(endpoint: endpoint, region: region, bucket: bucket,
                          accessKey: accessKey, secretKey: secretKey))
    }
}
