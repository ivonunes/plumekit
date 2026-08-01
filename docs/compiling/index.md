# Compiling templates

Plume has one language, one front-end and two back-ends. The interpreting renderer powers static-site generation. The compiling back-end turns a template into Swift source that renders at request time with no interpreter in the loop. The same `.plume` file is the source for both.

This page covers the compiler: what it accepts, what the generated code looks like and how behaviour hooks reach the browser.

## The two back-ends

- The **interpreting renderer** is dynamic and feature-complete: scoped styles, client scripts, the asset pipeline, host functions, `@state` and the full filter library.
- The **compiling back-end** lowers a template to Swift source that compiles under Embedded Swift: a typed `render` function that writes HTML bytes. This is what a request-time view layer (for example, a Cloudflare Workers Wasm isolate) uses to render views.

The compiling back-end accepts a dynamically-renderable subset of the language (described below) and rejects the rest with clear, source-located errors.

## Compiling

Compile a directory of templates with `plumekit compile`:

```sh
plumekit compile Views/                 # print generated Swift to stdout
plumekit compile Views/ -o Generated/   # write one .swift per template
```

Each template is checked against the renderable subset first; any out-of-subset feature is reported as `path:line:col: message` and compilation stops with a non-zero exit. Valid templates emit Swift that imports `PlumeRuntime`.

## Typed props

For the compiled target, component parameters name a Swift type. The interpreting renderer ignores the annotation, so a typed component still renders on the static-site path unchanged.

A typed component looks like this:

```plume
@component PostPage(post: Post, related: [Post] = [], currentUser: User?) {
  <h1>{post.title}</h1>
  @for item in related { ... }
}
```

It lowers to a plain Swift function:

```swift
func postPage(post: Post, related: [Post] = [], currentUser: User?,
              into out: inout HTML) { ... }
```

### How constructs lower

- Defaults map to Swift default arguments; optionals stay optionals.
- `{post.title}` becomes the escaping `out.text(post.title)`; auto-escaping is the default.
- `{value | raw}` becomes `out.raw(value)`, the explicit unescaped opt-out.
- `@if` and `@for` become Swift `if` and `for`; `forloop` is available inside loops.
- `@Child(post: p)` becomes a typed call `child(post: p, into: &out)`.
- `@slot` and `@slot(name)` become optional render-closure parameters; an unfilled slot renders its fallback.

### Type errors

Member-level type checking is deferred to `swiftc`. Because generated code carries `#sourceLocation` directives, a type error (for example, interpolating a value that is not a `String`) is reported against the `.plume` line, not the generated Swift.

## The dynamically-renderable subset

Generated render functions are pure and synchronous: already-materialised data in, bytes out. No `await`, no I/O, no concurrency. Supported:

- Text, escaped interpolation (`{x}`) and the raw opt-out (`{x | raw}`).
- `@if` / `@else if` / `@else`, `@for ... in ...` (with `forloop`), `@let` and `@if let` optional binding.
- Components, component calls, default and named slots, and defaults.
- Embedded-safe filters: `plus`, `minus`, `times`, `dividedBy`, `modulo`, `abs`, `atLeast`, `atMost`, `round`, `ceil`, `floor`, `default`, plus `raw` and `escape`.
- Embedded-safe methods: `hasPrefix`/`startsWith`, `hasSuffix`/`endsWith`, `contains`.

Conditions must be `Bool` (`swiftc` enforces this), so write `@if posts.count > 0` or `@if flag`, not a bare non-boolean value.

### Byte-wise text handling

Inside the render layer, all text handling is byte-wise UTF-8: string equality in a template compiles to a byte-wise comparison, and the generated code never relies on `String ==`, case-folding or Unicode collation. This is a deliberate choice, not a platform limit. It keeps `PlumeRuntime` and the generated render code small, and it keeps the native and Wasm render output byte-for-byte identical. Human-text collation is not this layer's job.

Your own app code is not held to this: `plumekit build --target cloudflare` links Swift's Unicode data tables into the Wasm build automatically, so native `String` operations (`==`, `hasPrefix`, `lowercased()` and so on) work in handlers and models with full Unicode semantics.

## Behaviour hooks and the asset bundle

`@style`, `@script`, `@state` and `@navigation` are split between build time and request time. Their heavy parts (scoped CSS, compiling the client script language to JavaScript, and the Plume client runtime) are compiled once into a content-hashed bundle, via `plumekit bundle -o DIR` or the `PlumeAssetBundle` API.

The bundle files are content-hashed: `app.<hash>.css` holds the extracted scoped `@style` CSS and `app.<hash>.js` holds the compiled `@script` client scripts plus the Plume client runtime.

The render function emits only the HTML-side hooks:

- A scoped `@style` adds a `data-plume-scope-…` attribute to the component's tags; the CSS itself goes to the bundle. The scope id is computed identically on both sides, so the bundled CSS always matches the markup.
- `@state` lowers to a `<script type="application/json" data-plume-state>` hook whose initial values are computed from props at render time (JSON-encoded byte-wise).
- `@navigation` lowers to a static `<script data-plume-navigation>` marker.
- `@script` compiles into the bundle; the render function emits nothing inline.

### Automatic bundle tags

Bundle tags are injected automatically, so the author never writes a manual `<script src="app.js">` or stylesheet link. Any `@style` site records that the response needs the stylesheet; any `@script`, `@state` or `@navigation` site records that it needs the client script.

At the response boundary (`Response.view`), the required `<link>` and `<script>` tags are spliced into the document's `<head>`, wherever in the page the directives appeared. The tags are marked `data-plume-track` so client-side navigation falls back to a full load when a deploy changes the bundle hashes.

Fragments (no `<head>`) are left untouched. A page using none of these directives loads no bundle at all.

### Assets at build time

`asset("name")` resolves at build time to the content-hashed bundle URL, baked into the render function as a string literal: `asset("app.js")` becomes `/app.<hash>.js`, and `asset("logo.png")` becomes `/logo.png` for your own `Public/` files. Because the URL is a literal, no runtime `String` lookup links into the guest. In a compiled template the argument must be a string literal.

## Build-time-only features (rejected by the checker)

Using these in a compiled template is a checker error:

- `@image` and the responsive-image pipeline. (`asset(...)` is allowed; it resolves to a baked URL literal at build time, as above.)
- Host-provided functions.
- Foundation/Unicode-backed filters and methods: case-folding (`upcase`/`downcase`/`capitalize`, `uppercased`/`lowercased`), `slugify`, `date*`, `json`, `urlEncode`/`urlDecode`, `split`, `replace`/`replaceFirst`, `strip`/`lstrip`/`rstrip`, `truncate*`, `sort`/`sortNatural`, `map`/`where`, and similar.

## Continuous integration

A host `swift build` or `swift test` does not prove the Wasm side: some problems in compiled templates only surface when the Embedded-Swift build is actually linked. If your app targets Cloudflare, have CI build the Worker bundle on every change:

```sh
plumekit build --target cloudflare
```

This compiles the templates, builds the generated code with the Embedded-Swift Wasm SDK and links the Worker module, so a link-time failure shows up in the pull request rather than at deploy. The CI that `plumekit new` scaffolds already does this in its deploy job, as part of `plumekit deploy --target cloudflare`.
