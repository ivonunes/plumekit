# JSON

PlumeKit builds and parses JSON through a concrete value tree, `JSONValue`, plus `Accept`-based content negotiation. Foundation's `Codable` and `JSONEncoder` use runtime reflection, which is unavailable under Embedded Swift, so PlumeKit's JSON is serialised and parsed by byte instead. It works identically on the native server and the Cloudflare Worker.

## Building JSON

Build a `JSONValue` from its cases and return it with `.json`, which serialises it:

```swift
let body = JSONValue.object([
    ("id", .int(1)),
    ("title", .string("Hello")),
    ("tags", .array([.string("a"), .string("b")])),
])
return .json(body)            // Response.json serialises it
```

The cases are null, bool, int, double, string, array and ordered object. Serialisation is byte-wise: it escapes only what JSON requires, and UTF-8 passes through.

## Parsing JSON

`parseJSON(bytes)` and `parseJSON(string)` run a recursive-descent parser and return a `JSONValue?`. Read the result with `json["key"]`, `.stringValue`, `.intValue` and so on.

### Constraints from the Wasm build

Two constraints shape the implementation:

- No `Double(String)`: it links `strtod`, absent in embedded Wasm. Numbers are parsed by a byte-wise float routine, adequate for JSON but not bit-exact.
- Keys compare, and strings build and escape, by byte: the framework's own layers stay byte-wise to keep the Wasm module small (your own code in the guest has full Unicode `String` support, see [Portability](portability.md)).

## Models and JSON

Models cross the JSON boundary through the `@Model` row codec; there is no second codec to keep in sync:

```swift
post.jsonObject()              // { "id":1, "title":"…", "published":true, … }
jsonArray(posts)               // [ {...}, {...} ]
Post.fromJSON(request.json()!) // build from a client payload (by column name)
```

`jsonObject()` walks `schema.columns` and `columnValues()`. `fromJSON` maps a JSON object back into a `Row` by column name; absent keys become type defaults, so a payload without `id` is insert-ready.

## Content negotiation

A controller serves the same resource as JSON or HTML from one action, by checking what the client asked for:

```swift
func index(_ request: Request) async throws -> Response {
    let posts = try await Post.all(in: request.bindings.database)
    if request.wantsJSON { return .json(jsonArray(posts)) }   // Accept: application/json
    return .text(/* … */)                                     // else HTML/text
}
```

`request.wantsJSON` checks the `Accept` header, `request.hasJSONBody` checks `Content-Type` and `request.json()` parses the body.

## Limits

Request and response bodies are buffered in memory, not streamed. Keep very large payloads in [object storage](bindings.md) and pass references.

`NaN` and the infinities have no JSON representation and encode as `null`.
