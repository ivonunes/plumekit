import Foundation
import PlumeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The AWS Lambda runtime front-end — the third request entry point alongside
// the Cloudflare Worker (Wasm) and the native SwiftNIO server. A Lambda runs a
// NATIVE Swift binary per invocation, so this is closer to the native server than
// to Wasm, but invocation-scoped. It maps an API Gateway proxy event → PlumeKit
// `Request`, runs the SAME `Application`, and maps the `Response` back. The event
// mapping is pure (verified offline with real event JSON); `run` is the custom-
// runtime loop that only executes inside Lambda.
public enum LambdaAdapter {
    /// Unreserved set for percent-encoding a query key/value (everything else — `&`, `=`,
    /// `+`, space — is encoded).
    static let queryAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// API Gateway proxy event (HTTP API v2 or REST v1) → PlumeKit `Request`.
    public static func makeRequest(eventJSON: Data, context: Context) -> Request {
        let object = (try? JSONSerialization.jsonObject(with: eventJSON)) as? [String: Any] ?? [:]

        var methodName = "GET"
        var path = "/"
        var query = ""
        if let rc = object["requestContext"] as? [String: Any],
           let http = rc["http"] as? [String: Any], let method = http["method"] as? String {
            methodName = method                                            // HTTP API v2
            path = object["rawPath"] as? String ?? "/"
            query = object["rawQueryString"] as? String ?? ""
        } else if let method = object["httpMethod"] as? String {
            methodName = method                                            // REST API v1
            path = object["path"] as? String ?? "/"
            // Prefer the multi-value map (repeated params like ?tag=a&tag=b) and
            // percent-encode each pair, so a `&`/`=`/space in a value can't corrupt the
            // query the app re-parses. `queryStringParameters` collapses duplicates.
            func enc(_ s: String) -> String {
                s.addingPercentEncoding(withAllowedCharacters: LambdaAdapter.queryAllowed) ?? s
            }
            if let mv = object["multiValueQueryStringParameters"] as? [String: [String]] {
                var pairs: [String] = []
                for (k, values) in mv { for v in values { pairs.append(enc(k) + "=" + enc(v)) } }
                query = pairs.sorted().joined(separator: "&")
            } else if let qs = object["queryStringParameters"] as? [String: String] {
                query = qs.map { enc($0.key) + "=" + enc($0.value) }.sorted().joined(separator: "&")
            }
        }

        var headers = Headers()
        if let h = object["headers"] as? [String: String] { for (k, v) in h { headers.add(k, v) } }
        // HTTP API v2 delivers cookies in a top-level array, not the Cookie header.
        if let cookies = object["cookies"] as? [String], !cookies.isEmpty {
            headers.add("cookie", cookies.joined(separator: "; "))
        }

        var body: [UInt8] = []
        if let b = object["body"] as? String {
            if object["isBase64Encoded"] as? Bool == true, let decoded = Data(base64Encoded: b) {
                body = [UInt8](decoded)
            } else {
                body = Array(b.utf8)
            }
        }

        return Request(method: HTTPMethod(name: methodName) ?? .get,
                       path: path, query: query, headers: headers, body: body, context: context)
    }

    /// PlumeKit `Response` → API Gateway proxy response JSON.
    public static func responseJSON(_ response: Response) -> Data {
        // Set-Cookie can repeat; a single-valued `headers` map would drop all but one
        // (breaking login, which sets a session cookie and clears the flash cookie). So
        // Set-Cookies go in the `cookies` array (HTTP API v2) and `multiValueHeaders`
        // (REST API v1); each gateway reads the form it understands.
        var headersObject: [String: String] = [:]
        var setCookies: [String] = []
        for field in response.headers.fields {
            if field.name.lowercased() == "set-cookie" { setCookies.append(field.value) }
            else { headersObject[field.name] = field.value }
        }
        let isText = String(data: Data(response.body), encoding: .utf8) != nil
        var object: [String: Any] = [
            "statusCode": response.status,
            "headers": headersObject,
            "body": isText ? String(decoding: response.body, as: UTF8.self)
                           : Data(response.body).base64EncodedString(),
            "isBase64Encoded": !isText,
        ]
        if !setCookies.isEmpty {
            object["cookies"] = setCookies
            object["multiValueHeaders"] = ["set-cookie": setCookies]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// The pure per-invocation core (no network): map one event's bytes → the app's
    /// response bytes. Exercised directly in tests with real event JSON.
    public static func processInvocation(_ app: Application, context: Context, eventJSON: Data) async -> Data {
        let request = makeRequest(eventJSON: eventJSON, context: context)
        var response = await app.handle(request)
        // Lambda responses are one buffered payload — run a streamed body to
        // completion; a producer error becomes the 500 it would be natively.
        do {
            response = try await response.collectingStream()
        } catch {
            response = Response.text("500 Internal Server Error", status: 500)
        }
        return responseJSON(response)
    }

    /// The Lambda custom-runtime loop: poll the Runtime API, dispatch each event
    /// through `app`, post the response. Runs forever inside Lambda; pass
    /// `maxInvocations` to bound it (used by the mock-runtime test). Needs
    /// AWS_LAMBDA_RUNTIME_API.
    public static func run(_ app: Application, context: Context, maxInvocations: Int? = nil) async throws {
        guard let api = ProcessInfo.processInfo.environment["AWS_LAMBDA_RUNTIME_API"] else {
            throw AWSError.badURL("AWS_LAMBDA_RUNTIME_API not set (not running in Lambda)")
        }
        let base = "http://\(api)/2018-06-01/runtime/invocation"
        var count = 0
        while maxInvocations.map({ count < $0 }) ?? true {
            guard let nextURL = URL(string: base + "/next") else { break }
            let (eventData, response) = try await URLSession.shared.data(from: nextURL)
            let requestID = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Lambda-Runtime-Aws-Request-Id") ?? ""

            let body = await processInvocation(app, context: context, eventJSON: eventData)

            if let postURL = URL(string: base + "/\(requestID)/response") {
                var post = URLRequest(url: postURL)
                post.httpMethod = "POST"
                _ = try? await URLSession.shared.upload(for: post, from: body)
            }
            count += 1
        }
    }
}
