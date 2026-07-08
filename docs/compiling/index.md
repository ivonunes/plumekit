# Compiling templates

Plume has two back-ends over **one** language and one front-end:

- The **interpreting renderer** powers static-site generation. It is dynamic and
  feature-complete (scoped styles, client scripts, the asset pipeline, host
  functions, `@state` and the full filter library).
- The **compiling back-end** lowers a template to Swift source that compiles under
  Embedded Swift: a typed `render` function that writes HTML bytes. This is what a
  request-time view layer (for example, a Cloudflare Workers Wasm isolate) uses
  to render views with no interpreter in the loop.

The same `.plume` file is the source for both. The compiling back-end accepts a
**dynamically-renderable subset** of the language (below) and rejects the rest
with clear, source-located errors.

## Compiling

```sh
plumekit compile Views/                 # print generated Swift to stdout
plumekit compile Views/ -o Generated/   # write one .swift per template
```

Each template is checked against the renderable subset first; any out-of-subset
feature is reported as `path:line:col: message` and compilation stops with a
non-zero exit. Valid templates emit Swift that imports `PlumeRuntime`.

## Typed props

For the compiled target, component parameters name a **Swift type**. The
interpreting renderer ignores the annotation, so a typed component still renders
on the static-site path unchanged.

```plume
@component PostPage(post: Post, related: [Post] = [], currentUser: User?) {
  <h1>{post.title}</h1>
  @for item in related { ... }
}
```

lowers to:

```swift
func postPage(post: Post, related: [Post] = [], currentUser: User?,
              into out: inout HTML) { ... }
```

- Defaults map to Swift default arguments; optionals stay optionals.
- `{post.title}` → escaping `out.text(post.title)` (auto-escaping is the default).
- `{value | raw}` → `out.raw(value)` (the explicit unescaped opt-out).
- `@if` / `@for` → Swift `if` / `for`; `forloop` is available inside loops.
- `@Child(post: p)` → a typed call `child(post: p, into: &out)`.
- `@slot` / `@slot(name)` → optional render-closure parameters; an unfilled slot
  renders its fallback.

Member-level type checking is deferred to `swiftc`. Because generated code carries
`#sourceLocation` directives, a type error (for example, interpolating a value
that is not a `String`) is reported against the **`.plume`** line, not generated
Swift.

## The dynamically-renderable subset

Generated render functions are **pure and synchronous**: already-materialised
data in, bytes out. No `await`, no I/O, no concurrency. Supported:

- Text, escaped interpolation (`{x}`) and the raw opt-out (`{x | raw}`).
- `@if` / `@else if` / `@else`, `@for ... in ...` (with `forloop`), `@let`,
  `@if let` optional binding. Conditions must be `Bool` (`swiftc` enforces this),
  so write `@if posts.count > 0` or `@if flag`, not a bare non-boolean value.
- Components, component calls, default and named slots, and defaults.
- Embedded-safe filters: `plus`, `minus`, `times`, `dividedBy`, `modulo`, `abs`,
  `atLeast`, `atMost`, `round`, `ceil`, `floor`, `default`, plus `raw`/`escape`.
- Embedded-safe methods: `hasPrefix`/`startsWith`, `hasSuffix`/`endsWith`,
  `contains`.

All text handling is **byte-wise UTF-8**. The compiled back-end never relies on
`String ==`, case-folding or Unicode collation, because those fail to *link*
under Embedded Swift (the Unicode tables are absent). String equality is compiled
to a byte-wise comparison; human-text collation is not this layer's job.

## Behaviour hooks and the asset bundle

`@style`, `@script`, `@state` and `@navigation` are split between build time and
request time. Their heavy parts (scoped CSS, the client-script-language → JS
compilation and the Plume client runtime) are compiled once into a
content-hashed bundle (`plumekit bundle -o DIR`, or the `PlumeAssetBundle` API). The
render function emits only the HTML-side hooks:

- a scoped `@style` adds a `data-plume-scope-…` attribute to the component's tags;
  the CSS itself goes to the bundle. The scope id is computed identically on both
  sides, so the bundled CSS always matches the markup.
- `@state` lowers to a `<script type="application/json" data-plume-state>` hook
  whose initial values are computed from props at render time (JSON-encoded
  byte-wise).
- `@navigation` lowers to a static `<script data-plume-navigation>` marker.
- `@script` compiles into the bundle; the render function emits nothing inline.
- **Bundle tags are injected automatically.** Any `@style` site records that the
  response needs the stylesheet; any `@script`/`@state`/`@navigation` site records
  that it needs the client script. At the response boundary (`Response.view`), the
  required `<link>`/`<script>` are spliced into the document's `<head>`, wherever
  in the page the directives appeared, marked `data-plume-track` so client-side
  navigation falls back to a full load when a deploy changes the bundle hashes.
  Fragments (no `<head>`) are left untouched; a page using none of these
  directives loads no bundle at all. The author never writes a manual
  `<script src="app.js">` or stylesheet link.
- `asset("name")` resolves **at build time** to the content-hashed bundle URL,
  baked into the render function as a string literal (`asset("app.js")` →
  `/app.<hash>.js`; `asset("logo.png")` → `/logo.png` for your own `Public/`
  files). Because the URL is a literal, no runtime `String` lookup links into the
  guest. In a compiled template the argument must be a **string literal**.

The bundle files are content-hashed: `app.<hash>.css` (extracted scoped `@style`
CSS) and `app.<hash>.js` (`@script` client scripts plus the Plume client runtime).

## Build-time-only features (rejected by the checker)

Using these in a compiled template is a checker error:

- `@image` and the responsive-image pipeline. (`asset(...)` **is** allowed; it is
  resolved to a baked URL literal at build time, as above.)
- Host-provided functions.
- Foundation/Unicode-backed filters and methods: case-folding
  (`upcase`/`downcase`/`capitalize`, `uppercased`/`lowercased`), `slugify`,
  `date*`, `json`, `urlEncode`/`urlDecode`, `split`, `replace`/`replaceFirst`,
  `strip`/`lstrip`/`rstrip`, `truncate*`, `sort`/`sortNatural`, `map`/`where`,
  and similar.

## Continuous integration

`support/embedded-gate.sh` is the link-and-run gate: it runs `plumekit compile` on
`Fixtures/EmbeddedGate`, then builds the generated code with the Embedded-Swift
Wasm SDK, **links an executable**, runs it under Node's WASI and asserts the
rendered bytes. Linking (not just building a library) is required because Embedded
link-time failures are invisible to a library-only build.
