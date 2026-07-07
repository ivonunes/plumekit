// Typed form decoding: a protocol the type satisfies with an explicit
// mapping (no reflection, same philosophy as the ORM row codec / JSON codec).
// Works for urlencoded and multipart bodies (field parts).

public struct FormValues: Sendable {
    public let pairs: [(name: String, value: String)]

    public init(_ pairs: [(name: String, value: String)]) { self.pairs = pairs }

    public subscript(_ name: String) -> String? {
        for pair in pairs where utf8Equal(pair.name, name) { return pair.value }
        return nil
    }
    public func string(_ name: String, default defaultValue: String = "") -> String {
        self[name] ?? defaultValue
    }
    public func int(_ name: String) -> Int? { self[name].flatMap { Int($0) } }
    public func bool(_ name: String) -> Bool {
        guard let value = self[name] else { return false }
        return utf8Equal(value, "on") || utf8Equal(value, "true") || utf8Equal(value, "1")
    }
}

/// A type that decodes from submitted form values via an explicit mapping.
public protocol FormDecodable {
    init(form: FormValues)
}

extension Request {
    /// Decode the submitted body (urlencoded or multipart fields) into `T`.
    public func decode<T: FormDecodable>(_ type: T.Type) -> T {
        T(form: formValues())
    }

    /// Submitted form fields (multipart field parts, else the urlencoded body).
    public func formValues() -> FormValues {
        if let multipart = multipart() {
            var pairs: [(name: String, value: String)] = []
            for part in multipart.parts where part.filename == nil {
                pairs.append((name: part.name, value: decodeUTF8(part.body)))
            }
            return FormValues(pairs)
        }
        return FormValues(form.values)
    }

    /// Whether the client is Plume's `@navigation` runtime (wants a fragment /
    /// stream rather than a full page). Negotiation precedence with `wantsJSON`
    /// is the handler's to decide.
    public var wantsStream: Bool { headers.first("x-plume-navigation") != nil }
}
