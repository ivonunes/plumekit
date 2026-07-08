# Plume views in PlumeKit

[Plume](https://github.com/ivonunes/plumekit) is the view layer. A `.plume` template
compiles to an Embedded-Swift **render function** that writes into a `PlumeRuntime`
`HTML` buffer; a PlumeKit handler calls it and returns `HTML.bytes` as the response.
The same rendering runs natively (`plumekit serve`) and on Workers (Wasm), byte-identical.

## No separate Plume install

`plumekit` **embeds the Plume compiler** (a library dependency of the CLI), so it
compiles templates **in-process**: there is no separate Plume install and no
`PLUME_PATH`. `plumekit new`, `serve`, `console` and
`build` all run the embedded compiler:

```
Views/*.plume  ──(embedded Plume compiler, in `plumekit`)──▶  Sources/App/Generated/*.swift
```

Apps depend only on the **`PlumeRuntime`** product (fetched by
SwiftPM like any package dependency); that's what the generated code imports and
links against, native and Wasm.

## Authoring

Views are split across `.plume` files (a shared `Layout` component plus one file
per page), not a single monolithic template. A page fills the layout's slot:

`Views/Layout.plume`:

```plume
@component Layout(title: String) {<!doctype html>
<html><head><title>{title}</title></head>
<body>@slot</body></html>}
```

`Views/ItemsPage.plume`:

```plume
@component ItemsPage(title: String, items: [Item]) {@Layout(title: title) {
<h1>{title}</h1>@if items.size > 0 {<ul>@for item in items {<li>{forloop.index}. {item.name}</li>}</ul>} else {<p>No items.</p>}}}
```

`plumekit compile Views -o Sources/App/Generated` compiles **every** `.plume`
file to its own generated Swift file (one render function per component). The app
provides the data types (`Item`) and calls the page's render function in a handler:

```swift
import PlumeKit
import PlumeRuntime

app.get("/items") { _ in
    let items = [Item(name: "alpha"), Item(name: "Hello & <World>")]
    return .view(itemsPage(title: "PlumeKit + Plume", items: items))   // itemsPage(...) is generated
}
```

Each component is generated in two forms: `itemsPage(title:items:) -> HTML` (the
convenience used above) and `itemsPage(title:items:into: &out)`, which writes into an
existing buffer, the fast path the compiler uses to compose components together.

`{item.name}` is HTML-escaped by default, so `Hello & <World>` renders as
`Hello &amp; &lt;World&gt;`; escaping behaves identically on the edge.

## Organising views

`plumekit compile` recurses into subfolders, so group views however keeps the directory
tidy as the app grows: a shared `Layout` and partials at the root, a folder per resource
or section:

```text
Views/
  Layout.plume            # @component Layout, the shared shell
  HomePage.plume          # @component HomePage
  Post/
    Index.plume           # @component PostIndex
    Show.plume            # @component PostShow
  Admin/
    Dashboard.plume       # @component AdminDashboard
  Emails/
    VerifyEmail.plume     # email bodies are views too; keep them in their own folder
```

Folders are PascalCase like the rest of the tree. `plumekit generate resource` follows
this automatically: each resource's views land in `Views/<Name>/`. The folder is purely
for organisation: every `@component` compiles to a **top-level** render function, so its
name must be unique across the whole tree (`PostIndex`, not just `Index`). Generated files
are named by path (`Post/Index.plume` → `Post.Index.plume.swift`), so same-named files in
different folders never collide.

## How it fits together

- **`plumekit` CLI** depends on Plume's `Plume` compiler library → `compileTemplates`
  runs it in-process before every `serve`/`console`/`build` (and once at `new`).
- **The app** depends on `PlumeRuntime` and includes `Sources/App/Generated/*.swift`.
  `Response.html(bytes:)` (PlumeKit core) turns the rendered `HTML.bytes` into a
  response; `Response.view(_ HTML)` is a one-line app-level convenience.
- **PlumeKit's core stays view-engine-agnostic**: it knows only `[UInt8]`; the Plume
  coupling lives in the CLI (compiler) and the app (runtime).
