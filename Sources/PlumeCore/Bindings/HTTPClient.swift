import _Concurrency

// MARK: - The fetch / HTTP-client capability
//
// Outbound HTTP as a portable capability. Adapters: Cloudflare's global `fetch`
// (wasm, JSPI) and a native client. The surface is `fetch`-shaped: method, URL,
// headers, body in; status, headers, body out. Streaming is a later refinement.
// Everything goes through the binding — app code never calls a platform `fetch`
// directly.

/// An outbound request: method, URL, headers, body.
public struct FetchRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [(name: String, value: String)]
    public var body: [UInt8]

    public init(method: String = "GET", url: String,
                headers: [(name: String, value: String)] = [], body: [UInt8] = []) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// A fetched response: HTTP status + headers + body bytes.
public struct FetchResponse: Sendable {
    public let status: Int
    public let body: [UInt8]
    public let headers: [(name: String, value: String)]

    public init(status: Int, body: [UInt8], headers: [(name: String, value: String)] = []) {
        self.status = status
        self.body = body
        self.headers = headers
    }
    /// The body decoded as UTF-8.
    public var bodyText: String { decodeUTF8(body) }

    /// First header with this name (ASCII case-insensitive).
    public func header(_ name: String) -> String? {
        let target = asciiLowercaseBytes(Array(name.utf8))
        for h in headers where asciiLowercaseBytes(Array(h.name.utf8)) == target { return h.value }
        return nil
    }
}

func asciiLowercaseBytes(_ bytes: [UInt8]) -> [UInt8] {
    bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
}

/// What an HTTP-client adapter implements.
public protocol HTTPClient: Sendable {
    func get(_ url: String) async throws -> FetchResponse
    func request(_ request: FetchRequest) async throws -> FetchResponse
}

extension HTTPClient {
    /// GET-only adapters get `request` for free: a plain GET delegates to
    /// `get`; anything richer is unsupported there and returns status 0.
    public func request(_ request: FetchRequest) async throws -> FetchResponse {
        if request.method == "GET" && request.headers.isEmpty && request.body.isEmpty {
            return try await get(request.url)
        }
        return FetchResponse(status: 0, body: [])
    }
}

/// The Embedded-clean HTTP handle carried in `Context`.
public struct HTTP: Sendable {
    private let _get: @Sendable (String) async throws -> FetchResponse
    private let _request: @Sendable (FetchRequest) async throws -> FetchResponse

    public init(_ adapter: some HTTPClient) {
        self._get = { try await adapter.get($0) }
        self._request = { try await adapter.request($0) }
    }
    public init(get: @escaping @Sendable (String) async throws -> FetchResponse) {
        self._get = get
        self._request = { req in
            if req.method == "GET" && req.headers.isEmpty && req.body.isEmpty {
                return try await get(req.url)
            }
            return FetchResponse(status: 0, body: [])
        }
    }
    public func get(_ url: String) async throws -> FetchResponse { try await _get(url) }
    /// Full-fidelity request: method, headers, body.
    public func request(_ request: FetchRequest) async throws -> FetchResponse {
        try await _request(request)
    }
}

// MARK: - Request/response wire codec (shared by the Wasm guest and host shims)
//
// Request:  [u8 methodLen][method][u32 urlLen][url][u16 headerCount]
//           ([u16 nameLen][name][u16 valueLen][value])* [u32 bodyLen][body]
// Response: [u16 status][u16 headerCount]
//           ([u16 nameLen][name][u16 valueLen][value])* [body…]
// All integers little-endian.

public enum FetchWire {
    public static func encodeRequest(_ request: FetchRequest) -> [UInt8] {
        var out: [UInt8] = []
        let method = Array(request.method.utf8)
        out.append(UInt8(method.count & 0xFF))
        out.append(contentsOf: method)
        let url = Array(request.url.utf8)
        appendU32(&out, url.count)
        out.append(contentsOf: url)
        appendU16(&out, request.headers.count)
        for header in request.headers {
            let name = Array(header.name.utf8)
            let value = Array(header.value.utf8)
            appendU16(&out, name.count)
            out.append(contentsOf: name)
            appendU16(&out, value.count)
            out.append(contentsOf: value)
        }
        appendU32(&out, request.body.count)
        out.append(contentsOf: request.body)
        return out
    }

    public static func decodeResponse(_ bytes: [UInt8]) -> FetchResponse {
        guard bytes.count >= 4 else { return FetchResponse(status: 0, body: []) }
        let status = Int(bytes[0]) | (Int(bytes[1]) << 8)
        let headerCount = Int(bytes[2]) | (Int(bytes[3]) << 8)
        var i = 4
        var headers: [(name: String, value: String)] = []
        for _ in 0..<headerCount {
            guard i + 2 <= bytes.count else { return FetchResponse(status: status, body: []) }
            let nameLen = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2
            guard i + nameLen <= bytes.count else { break }
            let name = decodeUTF8(Array(bytes[i..<(i + nameLen)])); i += nameLen
            guard i + 2 <= bytes.count else { break }
            let valueLen = Int(bytes[i]) | (Int(bytes[i + 1]) << 8); i += 2
            guard i + valueLen <= bytes.count else { break }
            let value = decodeUTF8(Array(bytes[i..<(i + valueLen)])); i += valueLen
            headers.append((name, value))
        }
        let body = i < bytes.count ? Array(bytes[i...]) : []
        return FetchResponse(status: status, body: body, headers: headers)
    }

    static func appendU16(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    }
    static func appendU32(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }
}
