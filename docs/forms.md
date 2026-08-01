# Forms

Forms are how a browser sends data to your app: the user submits, your handler reads and validates the fields, then responds. This page covers reading form data (including file uploads), CSRF protection, validation and choosing the response.

Every form works with no JavaScript; the baseline response is a redirect or a re-rendered page. When Plume's `@navigation` client runtime is on the page (see [Driving the page](client/index.md)), the same handler can instead answer with a stream envelope, a targeted region swap, so the enhancement layers on top of the working baseline (see [Fragments and the stream envelope](streaming/index.md)). Everything works the same on the native server and on the Cloudflare Worker.

## Reading form data

A urlencoded body is parsed by `request.form`, which returns a `FormParams`:

```swift
let title = request.form["title"] ?? ""
```

### File uploads

A multipart body is parsed by `request.multipart()`. File parts stream to the `StorageDriver`, so the handler receives references, not bytes:

```swift
guard let form = request.multipart() else { return .status(400) }
let (fields, files) = try await form.upload(to: request.bindings.storage)
// files[i].key / .size / .filename; bytes live in object storage (filesystem/R2/S3)
```

Plain fields come back as `FormParams`, exactly like a urlencoded body. The file bytes live in object storage on every target: filesystem, R2 or S3.

## CSRF protection and method override

Two middleware make browser forms safe and expressive. Register both in `buildApp()`:

```swift
app.use(methodOverride())     // _method field → PUT/PATCH/DELETE (HTML forms only GET/POST)
app.use(csrfProtection())     // reject form/multipart POSTs without a valid token
```

`methodOverride()` lets a form drive `PUT`, `PATCH` and `DELETE` routes through a hidden `_method` field, since HTML forms can only issue `GET` and `POST`. `csrfProtection()` rejects form and multipart submissions that lack a valid CSRF token.

CSRF tokens are signed with HMAC-SHA256, keyed by the `CSRF_SECRET` secret, and compared in constant time. JSON APIs and bearer-token requests are exempt automatically.

### The @csrf directive

Scaffolded apps enable CSRF protection by default: `buildApp()` registers `csrfProtection()`, `plumekit new` writes a fresh `CSRF_SECRET` into `.env`, and forms carry the token via the `@csrf` directive. Put `@csrf` inside any `<form>` and it renders the hidden `_csrf` field with the right token:

```plume
<form method="post" action="/posts">
  @csrf
  ...
</form>
```

There is nothing to pass in and nothing to wire up. The token is per visitor, bound to the `plumekit_csrf` cookie, and unpredictable, so another site cannot forge it.

### Sending the token from JavaScript

If you POST with `fetch` instead of a form, send the token as the `X-CSRF-Token` header. `request.csrfToken()` returns it.

## Typed decoding

To move form data into a typed value instead of reading fields one by one, conform a struct to `FormDecodable` and call `request.decode`:

```swift
struct PostForm: FormDecodable {
    let title: String; let views: Int
    init(form: FormValues) { title = form.string("title"); views = form.int("views") ?? 0 }
}
let input = request.decode(PostForm.self)   // urlencoded or multipart fields
```

The mapping is explicit; nothing is derived by reflection. This is the same approach as the ORM row codec and the JSON codec.

## Re-rendering with old input and inline errors

When a form POST fails validation, the no-JS baseline is to re-render the page with status 422, the submitted values repopulated and a message next to each bad field.

`input.errors.first("title")` returns the field's first message, or `""` when the field is clean, so a template can gate on it directly:

```swift
let input = request.validate([("title", [.required]), ("views", [.integer])])
guard input.isValid else {
    return .view(postIndex(items: items,
                           oldTitle: input.string("title"),
                           titleError: input.errors.first("title")),
                 status: 422)
}
```

The template shows the old value and the error together:

```plume
<p><input name="title" value="{oldTitle}">
@if titleError != "" {<span class="field-error">{titleError}</span>}</p>
```

`generate resource` scaffolds this whole flow: `.required` on every field, plus `.integer` or `.decimal` for numeric ones. See [Validations](validations.md#request-validation) for the rule set.

## Negotiated responses

One handler can serve three representations, chosen by negotiation: an `X-Plume-Navigation` header gets a stream, `Accept: application/json` gets JSON and everything else gets a full page:

```swift
let errors = try await post.save(in: db)        // validation
if !errors.isEmpty {
    if request.wantsJSON  { return .json(errorsJSON(errors), status: 422) }   // API: structured errors
    let form = renderPostForm(title: post.title, errors: errors)              // errors + preserved input
    if request.wantsStream { return .stream(envelope.replace("post-form", form)) }  // JS: targeted swap
    return .view(fullPage(form), status: 422)                                 // no-JS: full page
}
if request.wantsStream { return .stream(envelope.prepend("post-list", card)) } // JS: targeted update
return .redirect(to: "/posts/new")                                            // no-JS: POST-redirect-GET
```

Errors negotiate too: an API client gets JSON, not HTML.

## The client runtime

The stream path uses Plume's `StreamEnvelope` and the `@navigation` client runtime, which intercepts `submit`, falls back to a normal POST with no JavaScript and applies `<plume-stream>` responses. `StreamEnvelope` and `<plume-stream>` are covered in [Fragments and the stream envelope](streaming/index.md); the `@navigation` runtime is covered in [Driving the page](client/index.md).
