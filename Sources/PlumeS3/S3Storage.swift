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
        let (data, status, _) = try await send("GET", key: key, body: nil)
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw S3Error.http(status, String(decoding: data, as: UTF8.self)) }
        return [UInt8](data)
    }

    public func put(_ key: String, _ bytes: [UInt8]) async throws {
        let (data, status, _) = try await send("PUT", key: key, body: Data(bytes))
        guard (200..<300).contains(status) else { throw S3Error.http(status, String(decoding: data, as: UTF8.self)) }
    }

    public func delete(_ key: String) async throws {
        let (data, status, _) = try await send("DELETE", key: key, body: nil)
        guard (200..<300).contains(status) || status == 404 else {
            throw S3Error.http(status, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Signed request

    private func send(_ method: String, key: String, query: [(String, String)] = [],
                      body: Data?) async throws -> (Data, Int, etag: String?) {
        guard let base = URL(string: endpoint) else { throw S3Error.badEndpoint(endpoint) }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? key
        let canonicalURI = "/\(bucket)/\(encodedKey)"
        // SigV4 canonical query: strict-encoded pairs, sorted by name. The SAME
        // string goes on the URL, so what's signed is exactly what's sent.
        let canonicalQuery = query
            .map { (Self.strictEncode($0.0), Self.strictEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let target = endpoint + canonicalURI + (canonicalQuery.isEmpty ? "" : "?" + canonicalQuery)
        guard let url = URL(string: target) else { throw S3Error.badEndpoint(endpoint) }
        let host = base.host! + (base.port.map { ":\($0)" } ?? "")

        let payload = body ?? Data()
        let payloadHash = SigV4.payloadHash(payload)
        let (amzDate, dateStamp) = SigV4.timestamps()

        let signer = SigV4(region: region, service: "s3", accessKey: accessKey, secretKey: secretKey)
        let authorization = signer.authorization(
            method: method, canonicalURI: canonicalURI, canonicalQuery: canonicalQuery,
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
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "ETag"))
    }

    /// RFC 3986 unreserved-only encoding for query names/values (SigV4's rule).
    private static func strictEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? value
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Unreserved path characters per RFC 3986 (S3 keys; `/` left to the caller).
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")   // keep `/` literal so "a/b.jpg" stays a path, not "a%2Fb.jpg"
        return set
    }()
}

// MARK: - Streaming put (multipart upload)

extension S3Storage: StreamingStorageDriver {
    /// Multipart part size. S3 requires ≥5 MB for every part but the last; 8 MB
    /// keeps request count low while bounding memory per in-flight upload.
    static let multipartPartBytes = 8 * 1024 * 1024

    /// Stream chunks into S3. Small objects (the stream ends inside the first
    /// part) go up as one plain PUT; anything larger becomes a multipart upload —
    /// only one part is ever held in memory. A failure aborts the upload
    /// server-side so no orphaned parts accrue storage charges.
    public func put(_ key: String, from reader: RequestBodyReader) async throws {
        var part: [UInt8] = []
        var ended = false
        func fill() async throws {
            while !ended && part.count < Self.multipartPartBytes {
                if let chunk = try await reader.next() { part.append(contentsOf: chunk) }
                else { ended = true }
            }
        }

        try await fill()
        if ended {
            try await put(key, part)   // fits in one part → plain PUT
            return
        }

        let uploadID = try await createMultipartUpload(key: key)
        do {
            var etags: [String] = []
            var partNumber = 1
            while !part.isEmpty {
                etags.append(try await uploadPart(key: key, uploadID: uploadID,
                                                  number: partNumber, body: part))
                partNumber += 1
                part = []
                try await fill()
            }
            try await completeMultipartUpload(key: key, uploadID: uploadID, etags: etags)
        } catch {
            try? await abortMultipartUpload(key: key, uploadID: uploadID)
            throw error
        }
    }

    private func createMultipartUpload(key: String) async throws -> String {
        let (data, status, _) = try await send("POST", key: key, query: [("uploads", "")], body: Data())
        guard (200..<300).contains(status) else {
            throw S3Error.http(status, String(decoding: data, as: UTF8.self))
        }
        let xml = String(decoding: data, as: UTF8.self)
        guard let open = xml.range(of: "<UploadId>"), let close = xml.range(of: "</UploadId>"),
              open.upperBound <= close.lowerBound else {
            throw S3Error.http(status, "multipart create: no UploadId in response")
        }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private func uploadPart(key: String, uploadID: String, number: Int, body: [UInt8]) async throws -> String {
        let (data, status, etag) = try await send(
            "PUT", key: key,
            query: [("partNumber", String(number)), ("uploadId", uploadID)],
            body: Data(body))
        guard (200..<300).contains(status), let etag else {
            throw S3Error.http(status, String(decoding: data, as: UTF8.self))
        }
        return etag
    }

    private func completeMultipartUpload(key: String, uploadID: String, etags: [String]) async throws {
        var xml = "<CompleteMultipartUpload>"
        for (index, etag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let (data, status, _) = try await send("POST", key: key, query: [("uploadId", uploadID)],
                                               body: Data(xml.utf8))
        guard (200..<300).contains(status) else {
            throw S3Error.http(status, String(decoding: data, as: UTF8.self))
        }
    }

    private func abortMultipartUpload(key: String, uploadID: String) async throws {
        _ = try await send("DELETE", key: key, query: [("uploadId", uploadID)], body: nil)
    }
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
