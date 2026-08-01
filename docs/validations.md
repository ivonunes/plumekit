# Validations

Validations keep bad data out of the database. You declare rules on a model, they run automatically on `save()`, and failures come back as field-level errors ready for a 422 response. The same rules run on native SQLite and Cloudflare D1, and a separate helper validates incoming request data before you use it.

## Declaring rules

Rules are concrete values holding closures (not keypaths, which do not compile under embedded Wasm). Each rule declares which field, how to read it and what to check:

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

The built-in sync rules are `presence`, `length(min:max:)`, `atLeast`, `atMost` and `custom`. The async rules, `unique` and `custom`, may query the database: uniqueness runs through the same `SQLDatabase` on both targets, and excludes the row itself on updates.

### Constraints from the Wasm build

Two constraints shape the rule API:

- Length is UTF-8 bytes, not graphemes: the framework's own layers stay byte-wise to keep the Wasm module small. For ASCII the two are identical; for anything else, use `custom` (your own code in the guest has full Unicode `String` support, see [Portability](portability.md)).
- No regex: a regex engine is not available in the Wasm guest. Use `custom` with byte-level checks.

## Errors as return values

`save()` validates first. If the model is invalid, it returns the errors without persisting; DB errors still `throw` and propagate:

```swift
let errors = try await post.save(in: db)
if errors.isEmpty {
    // saved
} else {
    // 422; errors is [ValidationError(field:message:)]
}
```

Returning the errors rather than throwing them is deliberate: embedded Swift forbids `catch … as SomeError` (dynamic casting) and `any Error` values, so a thrown-and-caught typed error would not compile for the worker. One code path works on both targets.

To check without saving, call `validate()` (sync) or `validate(in: db)` (async, including uniqueness). `isValid` is the sync shortcut.

## Request validation

The rules above validate a model on `save()`. Incoming request data (form or JSON) often needs checking before it ever reaches a model. For that, call `request.validate`:

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

`request.validate` reads each field from the JSON body (when the request is JSON) or the urlencoded form. An empty optional field is skipped; an empty required field reports "is required".

The rules are `.required`, `.email`, `.integer`, `.decimal`, `.min` and `.max` (numeric), `.minLength` and `.maxLength`, `.oneOf`, `.sameAs`, and `.check(message, predicate)` for anything custom.

### Using the result

`input.string`, `input.int` and `input.bool` return the validated values. `input.errors.jsonValue` is a ready-to-serialise `{"field": ["message"]}` object for a 422 body.

For HTML forms, `input.errors.first("email")` returns the field's first message, or `""` when the field is clean, so a template can gate an inline error on it directly. That is the piece a 422 re-render is built from: old input back in the fields, a message next to each bad one. See [Forms](forms.md#re-rendering-with-old-input-and-inline-errors).
