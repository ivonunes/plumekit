import Foundation
import Crypto
import PlumeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AWSError: Error, CustomStringConvertible {
    case badURL(String), http(Int, String)
    public var description: String {
        switch self {
        case .badURL(let u): return "aws bad url: \(u)"
        case .http(let code, let body): return "aws http \(code): \(body)"
        }
    }
}

// Sign + send a single AWS REST request with SigV4. Shared by the SQS/SSM adapters
// (and available to any other AWS service adapter).
enum AWSHTTP {
    static func send(
        signer: SigV4, method: String, urlString: String,
        contentType: String? = nil, amzTarget: String? = nil, body: Data = Data()
    ) async throws -> (Data, Int) {
        guard let url = URL(string: urlString), let host = url.host else { throw AWSError.badURL(urlString) }
        let hostHeader = host + (url.port.map { ":\($0)" } ?? "")
        let (amzDate, dateStamp) = SigV4.timestamps()
        let payloadHash = SigV4.payloadHash(body)

        var signed: [(name: String, value: String)] = [
            ("host", hostHeader),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        if let contentType { signed.append(("content-type", contentType)) }
        if let amzTarget { signed.append(("x-amz-target", amzTarget)) }

        let authorization = signer.authorization(
            method: method,
            canonicalURI: url.path.isEmpty ? "/" : url.path,
            canonicalQuery: url.query ?? "",
            headers: signed, payloadHash: payloadHash, amzDate: amzDate, dateStamp: dateStamp)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "content-type") }
        if let amzTarget { request.setValue(amzTarget, forHTTPHeaderField: "x-amz-target") }

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - SQS (MessageQueue)

/// SQS-backed message queue. Conforms the SAME `MessageQueue` protocol as the
/// Cloudflare Queues and native in-process adapters. Bytes are base64-encoded into
/// the SQS MessageBody (SQS bodies are text), so arbitrary job envelopes round-trip;
/// the consumer base64-decodes.
public struct SQSQueue: MessageQueue {
    let queueURL: String
    let signer: SigV4

    public init(queueURL: String, region: String, accessKey: String, secretKey: String) {
        self.queueURL = queueURL
        self.signer = SigV4(region: region, service: "sqs", accessKey: accessKey, secretKey: secretKey)
    }

    public func send(_ body: [UInt8]) async throws {
        let base64 = Data(body).base64EncodedString()
        let form = "Action=SendMessage&Version=2012-11-05&MessageBody=" + Self.formEncode(base64)
        let (data, status) = try await AWSHTTP.send(
            signer: signer, method: "POST", urlString: queueURL,
            contentType: "application/x-www-form-urlencoded", body: Data(form.utf8))
        guard (200..<300).contains(status) else {
            throw AWSError.http(status, String(decoding: data, as: UTF8.self))
        }
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - SSM Parameter Store (SecretStore)

/// SSM Parameter Store-backed secrets. Conforms the SAME `SecretStore` protocol as
/// the Cloudflare env-secrets and native env adapters. Uses the JSON protocol
/// (AmazonSSM.GetParameter) with decryption.
public struct SSMSecrets: SecretStore {
    let endpoint: String
    let signer: SigV4

    public init(region: String, accessKey: String, secretKey: String, endpoint: String? = nil) {
        self.endpoint = (endpoint ?? "https://ssm.\(region).amazonaws.com").trimmingSlash() + "/"
        self.signer = SigV4(region: region, service: "ssm", accessKey: accessKey, secretKey: secretKey)
    }

    public func secret(_ name: String) async throws -> [UInt8]? {
        let payload = #"{"Name":"\#(name)","WithDecryption":true}"#
        let (data, status) = try await AWSHTTP.send(
            signer: signer, method: "POST", urlString: endpoint,
            contentType: "application/x-amz-json-1.1", amzTarget: "AmazonSSM.GetParameter",
            body: Data(payload.utf8))
        if status == 400 { return nil }   // ParameterNotFound
        guard (200..<300).contains(status) else {
            throw AWSError.http(status, String(decoding: data, as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parameter = object["Parameter"] as? [String: Any],
              let value = parameter["Value"] as? String else { return nil }
        return Array(value.utf8)
    }
}

// MARK: - Drivers (called by the generated composition for the aws profile)

public enum SQSDriver {
    public static func connect(queueURL: String, region: String, accessKey: String, secretKey: String) -> Queue {
        Queue(SQSQueue(queueURL: queueURL, region: region, accessKey: accessKey, secretKey: secretKey))
    }
}

public enum SSMDriver {
    public static func connect(region: String, accessKey: String, secretKey: String,
                               endpoint: String? = nil) -> Secrets {
        Secrets(SSMSecrets(region: region, accessKey: accessKey, secretKey: secretKey, endpoint: endpoint))
    }
}
