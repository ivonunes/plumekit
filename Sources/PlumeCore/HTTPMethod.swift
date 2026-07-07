/// The HTTP methods PlumeKit routes on.
///
/// `rawValue` doubles as the stable wire code used by the Wasm worker ABI
/// (see `PlumeWorker`), so the order here is part of that contract — append
/// new cases, don't reorder.
public enum HTTPMethod: UInt8, Sendable, Equatable {
    case get = 0
    case post = 1
    case put = 2
    case patch = 3
    case delete = 4
    case head = 5
    case options = 6

    /// Uppercase method name, e.g. `GET`. Avoids Foundation so it stays Embedded-clean.
    public var name: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .head: return "HEAD"
        case .options: return "OPTIONS"
        }
    }

    /// Parse a method name (case-sensitive uppercase, as it appears on the wire).
    ///
    /// Uses byte comparison rather than `switch` over `String` so it links under
    /// embedded wasm (string switches lower to Unicode-aware `==`).
    public init?(name: String) {
        if utf8Equal(name, "GET") { self = .get }
        else if utf8Equal(name, "POST") { self = .post }
        else if utf8Equal(name, "PUT") { self = .put }
        else if utf8Equal(name, "PATCH") { self = .patch }
        else if utf8Equal(name, "DELETE") { self = .delete }
        else if utf8Equal(name, "HEAD") { self = .head }
        else if utf8Equal(name, "OPTIONS") { self = .options }
        else { return nil }
    }
}
