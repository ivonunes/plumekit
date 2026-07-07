// API resource transformers — one place per model that decides how it appears in
// JSON, used everywhere it's serialized (reflection-free: the transformer IS code):
//
//     extension Post: JSONRepresentable {
//         var jsonValue: JSONValue {
//             .object([("id", .int(Int64(id))), ("title", .string(title))])
//         }
//     }
//
//     return .json(post)                    // one resource
//     return .json(posts)                   // an array of them
//     return .json(page)                    // a Page — items + pagination metadata
//
// Keeping the shape explicit (not derived from stored properties) is the point: the
// API contract never accidentally grows a column you didn't mean to expose.

/// A value with a canonical JSON representation.
public protocol JSONRepresentable {
    var jsonValue: JSONValue { get }
}

extension Response {
    /// Serialize one resource: `return .json(post)`.
    public static func json(_ resource: some JSONRepresentable, status: Int = 200) -> Response {
        .json(resource.jsonValue, status: status)
    }

    /// Serialize a list of resources: `return .json(posts)`.
    public static func json(_ resources: [some JSONRepresentable], status: Int = 200) -> Response {
        .json(JSONValue.array(resources.map(\.jsonValue)), status: status)
    }
}
