import Foundation
import PlumeCore

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

/// Native outbound HTTP via URLSession. (SwiftNIO's AsyncHTTPClient is the
/// intended reference client; URLSession keeps this dependency-free and real.)
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: String) async throws -> FetchResponse {
        try await request(FetchRequest(url: url))
    }

    public func request(_ fetchRequest: FetchRequest) async throws -> FetchResponse {
        guard let parsed = URL(string: fetchRequest.url) else {
            throw FetchError.badURL(fetchRequest.url)
        }
        var urlRequest = URLRequest(url: parsed)
        urlRequest.httpMethod = fetchRequest.method
        for header in fetchRequest.headers {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if !fetchRequest.body.isEmpty {
            urlRequest.httpBody = Data(fetchRequest.body)
        }
        urlRequest.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        var headers: [(name: String, value: String)] = []
        if let fields = httpResponse?.allHeaderFields {
            for (key, value) in fields {
                if let name = key as? String {
                    headers.append((name, "\(value)"))
                }
            }
        }
        return FetchResponse(status: httpResponse?.statusCode ?? 0,
                             body: [UInt8](data), headers: headers)
    }

    public enum FetchError: Error { case badURL(String) }
}
