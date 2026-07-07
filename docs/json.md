# JSON

JSON plus `Accept`-based content negotiation. Foundation's
`Codable`/`JSONEncoder` use runtime reflection, which is unavailable under Embedded
Swift, so PlumeKit's JSON is a concrete value tree serialized and parsed by byte.
It works identically on the native server and the Wasm worker.

## JSONValue

```swift
let body = JSONValue.object([
    ("id", .int(1)),
    ("title", .string("Hello")),
    ("tags", .array([.string("a"), .string("b")])),
])
return .json(body)            // Response.json serializes it
```

`JSONValue` (null/bool/int/double/string/array/ordered-object) serializes byte-wise
(escapes only what JSON requires; UTF-8 passes through) and parses via a
recursive-descent parser. `parseJSON(bytes)`/`parseJSON(string)` returns a
`JSONValue?`; read it with `json["key"]`, `.stringValue`, `.intValue`, etc.

Two constraints from the Wasm build:
- **No `Double(String)`**: it links `strtod`, absent in embedded wasm; numbers
  are parsed by a byte-wise float routine (adequate for JSON, not bit-exact).
- No Unicode-aware String ops: keys compare and strings build/escape by byte.

## Models ⇄ JSON (the ORM seam)

The `@Model` row codec is reused for JSON; there is no second codec:

```swift
post.jsonObject()              // { "id":1, "title":"…", "published":true, … }
jsonArray(posts)               // [ {...}, {...} ]
Post.fromJSON(request.json()!) // build from a client payload (by column name)
```

`jsonObject()` walks `schema.columns` + `columnValues()`; `fromJSON` maps a JSON
object back into a `Row` by column name (absent keys → type defaults, so
a payload without `id` is insert-ready).

## Content negotiation

```swift
func index(_ request: Request) async throws -> Response {
    let posts = try await Post.all().all(in: request.bindings.database)
    if request.wantsJSON { return .json(jsonArray(posts)) }   // Accept: application/json
    return .text(/* … */)                                     // else HTML/text
}
```

`request.wantsJSON` (an `Accept` check), `request.hasJSONBody`
(`Content-Type`), and `request.json()` (parse the body). A controller serves the
same resource as JSON or HTML from one action.


## Notes

Request and response bodies are buffered in memory, not streamed; keep very large
payloads in [object storage](bindings.md) and pass references. `NaN` and the
infinities have no JSON representation and encode as `null`.
