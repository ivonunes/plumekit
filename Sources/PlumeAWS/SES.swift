import Foundation
import PlumeCore

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// SES mailer + a native URLSession HTTP client — the AWS backing for the Mailer and
// HTTPClient capabilities. SES uses the SES v2 JSON API over the shared SigV4 sender;
// both endpoints are overridable for LocalStack.

// MARK: - SES (MailSender)

/// Transactional email over Amazon SES (v2 `SendEmail`). Conforms the same
/// `MailSender` protocol as the native SMTP/log and Cloudflare adapters.
public struct SESMailer: MailSender {
    let endpoint: String
    let signer: SigV4

    public init(region: String, accessKey: String, secretKey: String, endpoint: String? = nil) {
        self.endpoint = (endpoint ?? "https://email.\(region).amazonaws.com").trimmingSlash()
        self.signer = SigV4(region: region, service: "ses", accessKey: accessKey, secretKey: secretKey)
    }

    public func send(_ message: EmailMessage) async throws {
        var content: [String: Any] = ["Subject": ["Data": message.subject]]
        var body: [String: Any] = ["Text": ["Data": message.textBody]]
        if let html = message.htmlBody { body["Html"] = ["Data": html] }
        content["Body"] = body

        var payload: [String: Any] = [
            "FromEmailAddress": message.from,
            "Destination": ["ToAddresses": [message.to]],
            "Content": ["Simple": content],
        ]
        if let replyTo = message.replyTo { payload["ReplyToAddresses"] = [replyTo] }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let (respData, status) = try await AWSHTTP.send(
            signer: signer, method: "POST", urlString: endpoint + "/v2/email/outbound-emails",
            contentType: "application/json", body: data)
        guard (200..<300).contains(status) else {
            throw MailError("SES send failed (\(status)): " + String(decoding: respData, as: UTF8.self))
        }
    }
}

// MARK: - HTTP client (URLSession)

/// The outbound HTTP client for the AWS target — a plain URLSession GET, mirroring
/// the native server's client so app code using `request.bindings.http` runs on
/// Lambda unchanged.
public struct URLSessionFetchClient: HTTPClient {
    public init() {}
    public func get(_ url: String) async throws -> FetchResponse {
        guard let u = URL(string: url) else { throw AWSError.badURL(url) }
        let (data, response) = try await URLSession.shared.data(from: u)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return FetchResponse(status: status, body: [UInt8](data))
    }
}

// MARK: - Drivers

public enum SESDriver {
    public static func connect(region: String, accessKey: String, secretKey: String,
                               endpoint: String? = nil) -> Mailer {
        Mailer(SESMailer(region: region, accessKey: accessKey, secretKey: secretKey, endpoint: endpoint))
    }
}

public enum AWSHTTPDriver {
    public static func connect() -> HTTP { HTTP(URLSessionFetchClient()) }
}
