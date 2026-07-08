# Forms

The request-path half of HTML-over-the-wire: form submit → validate → mutate →
respond with a **redirect** (full-page) or a **stream envelope** (targeted region
swap). Progressive enhancement is mandatory: every form works with no JavaScript;
Plume's `@navigation` runtime layers fetch-and-swap on top. Everything works the
same on the native server and on Cloudflare D1.

## Body parsing

- urlencoded via `request.form` (`FormParams`).
- multipart via `request.multipart()`. File parts stream to the
  `StorageDriver`; the handler gets references, not bytes:

```swift
let (fields, files) = try await form.upload(to: request.bindings.storage)
// files[i].key / .size / .filename; bytes live in object storage (filesystem/R2/S3)
```

## CSRF + method override (middleware)

```swift
app.use(methodOverride())     // _method field → PUT/PATCH/DELETE (HTML forms only GET/POST)
app.use(csrfProtection())     // reject form/multipart POSTs without a valid token
```

CSRF tokens are signed with HMAC-SHA256, keyed by the `CSRF_SECRET` secret;
comparison is constant-time. JSON APIs and bearer-token requests are exempt
automatically.

**Scaffolded apps enable this by default**: `buildApp()` registers `csrfProtection()`,
`plumekit new` writes a fresh `CSRF_SECRET` into `.env`, and forms carry the token via
the `@csrf` directive. Put `@csrf` inside any `<form>` and it renders the hidden
`_csrf` field with the right token. There is nothing to pass in and nothing to wire up:

```plume
<form method="post" action="/posts">
  @csrf
  ...
</form>
```

The token is per visitor (bound to the `plumekit_csrf` cookie) and unpredictable, so
another site can't forge it. If you POST with `fetch` instead of a form, send the
token as the `X-CSRF-Token` header; `request.csrfToken()` returns it.

## Typed decode

```swift
struct PostForm: FormDecodable {
    let title: String; let views: Int
    init(form: FormValues) { title = form.string("title"); views = form.int("views") ?? 0 }
}
let input = request.decode(PostForm.self)   // urlencoded or multipart fields
```

The mapping is explicit; nothing is derived by reflection. Same approach as the ORM
row codec and the JSON codec.

## Re-rendering with old input and inline errors

The no-JS baseline for a failed form POST: re-render the page with **422**, the
submitted values repopulated and a message next to each bad field.
`input.errors.first("title")` returns the field's first message, or `""` when the
field is clean, so a template can gate on it directly:

```swift
let input = request.validate([("title", [.required]), ("views", [.integer])])
guard input.isValid else {
    return .view(postIndex(items: items,
                           oldTitle: input.string("title"),
                           titleError: input.errors.first("title")),
                 status: 422)
}
```

```plume
<p><input name="title" value="{oldTitle}">
@if titleError != "" {<span class="field-error">{titleError}</span>}</p>
```

`generate resource` scaffolds this whole flow: `.required` on every field, plus
`.integer`/`.decimal` for numeric ones. See
[Validations](validations.md#request-validation) for the rule set.

## Negotiated responses (success and errors)

One handler, three representations, chosen by negotiation (`X-Plume-Navigation` →
stream; `Accept: application/json` → JSON; else full page):

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

The stream path uses Plume's `StreamEnvelope` and the `@navigation` client runtime,
which intercepts `submit`, falls back to a normal POST with no JS and applies
`<plume-stream>` responses.
