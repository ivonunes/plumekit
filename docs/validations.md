# Validations

Model validations that run automatically on `save()` and surface field-level
errors. The same rules run on native SQLite and Cloudflare D1.

## Declaring rules

Rules are concrete values holding **closures** (not keypaths, which don't
compile under embedded wasm), so they declare *which field*, *how to read it*
and *what to check*:

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    var views = 0

    static let validations: [Validation<Post>] = [
        .presence("title")       { $0.title },
        .length("title", max: 200) { $0.title },   // byte length, not graphemes
        .atLeast("views", 0)     { $0.views },
    ]
    static let asyncValidations: [AsyncValidation<Post>] = [
        .unique("title", column: "title") { sqlText($0.title) },  // a DB query
    ]
}
```

Built-in sync rules: `presence`, `length(min:max:)`, `atLeast`, `atMost`,
`custom`. Async rules: `unique` (and `custom`) may query the database, so
uniqueness runs through the same `SQLDatabase` on both targets and excludes the
row itself on updates.

Two constraints from the Wasm build shape the API:
- **Length is UTF-8 bytes**, not graphemes: `String.count` needs Unicode tables
  that don't link under embedded wasm. For ASCII they're
  identical; for anything else, use `custom`.
- **No regex** (also Unicode-dependent). Use `custom` with byte-level checks.

## Failure is a value, not an exception

`save()` validates first and, if invalid, **returns the errors without
persisting** (DB errors still `throw` and propagate):

```swift
let errors = try await post.save(in: db)
if errors.isEmpty {
    // saved
} else {
    // 422; errors is [ValidationError(field:message:)]
}
```

This is deliberate: embedded Swift forbids `catch … as SomeError` (dynamic
casting) and `any Error` values, so a thrown-and-caught typed error wouldn't
compile for the worker. Returning the errors keeps one code path working on both
targets. `validate()` (sync) and `validate(in: db)` (async, incl. uniqueness) are
available for checking without saving; `isValid` is the sync shortcut.


## Request validation

The rules above validate a *model* on `save()`. To validate incoming *request* data
(form or JSON, before you use it), call
`request.validate`:

```swift
app.post("/signup") { request in
    let input = request.validate([
        ("email",    [.required, .email]),
        ("age",      [.required, .integer, .min(18)]),
        ("password", [.required, .minLength(8)]),
        ("confirm",  [.sameAs("password")]),
    ])
    guard input.isValid else { return .json(input.errors.jsonValue, status: 422) }

    let email = input.string("email")
    let age = input.int("age") ?? 0
    // …
}
```

`request.validate` reads each field from the JSON body (when the request is JSON) or the
urlencoded form. Rules: `.required`, `.email`, `.integer`, `.decimal`, `.min`/`.max`
(numeric), `.minLength`/`.maxLength`, `.oneOf`, `.sameAs`, and `.check(message, predicate)`
for anything custom. An empty optional field is skipped; an empty required field reports
"is required". `input.errors.jsonValue` is a ready-to-serialise `{"field": ["message"]}`
object for a 422 body, and `input.string`/`int`/`bool` return the validated values.

For HTML forms, `input.errors.first("email")` returns the field's first message, or
`""` when the field is clean, so a template can gate an inline error on it directly.
That's the piece a 422 re-render is built from: old input back in the fields, a
message next to each bad one. See
[Forms](forms.md#re-rendering-with-old-input-and-inline-errors).
