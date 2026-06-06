# Concepts

Plume works best when you treat a template as the source for one piece of a page: the HTML it renders, the components it calls, and the resources that belong to that markup.

The language stays small on purpose. Host applications provide the project shape, pass data, resolve assets, and decide how collected resources are emitted.

## Terms

- A template renders HTML from host-provided data.
- A component is a reusable template fragment with arguments and slots.
- A context is the data dictionary the host passes into rendering.
- A resource is a `@style`, `@script`, `@image`, or `asset()` reference collected while rendering.
- The runtime is optional browser JavaScript emitted by the host when a render result needs state, actions, or page navigation.

## Flow

Start with plain HTML and expressions:

```plume
<article>
  <h2>{post.title | default("Untitled")}</h2>
  {post.excerpt}
</article>
```

When the same shape appears more than once, extract a component:

```plume
@component PostCard(post, showExcerpt = true) {
  <article class="post-card">
    <h2>{post.title | default("Untitled")}</h2>
    @if showExcerpt {
      {post.excerpt}
    }
  </article>
}
```

When markup needs supporting CSS or behaviour, co-locate the resource with the markup that owns it:

```plume
@component PostCard(post) {
  @style(scoped) {
    .post-card {
      display: grid;
      gap: 0.75rem;
    }
  }

  <article class="post-card">
    <h2>{post.title}</h2>
    @slot
  </article>
}
```

## Files

Plume itself does not require a folder structure. The host decides how templates and components are discovered.

For larger sites, this shape keeps things predictable:

```txt
theme/
  layouts/
    default.plume
  pages/
    home.plume
    post.plume
    page.plume
  components/
    PostCard.plume
  styles/
    site.css
  scripts/
    site.plume
```

Inkstead Writer uses this structure by default when ejecting a theme. Smaller sites can still keep page templates directly under `theme/` when the host supports it.

## Naming

- Use PascalCase for component names, such as `PostCard` or `SiteHeader`.
- Use lower-case filenames for page templates, such as `home.plume` and `feed.xml.plume`.
- Prefer named arguments for options that are not the main value, such as `@PostCard(post, tone: "featured")`.
- Keep global layout resources in a layout template.
- Keep component resources inside the component when they belong only to that component.

## Host Boundary

Plume does not assume a web framework. A host can be a static site generator, a server-side Swift app, a build tool, or a custom renderer.

That boundary is why the same Plume syntax can work inside Inkstead Writer and inside another Swift application with different asset and deployment rules. For the Swift API and host responsibilities, see [Embedding](../embedding/index.md).

## Common Mistakes

- Do not write Liquid syntax like `{{ title }}` or `{% if post %}`.
- Do not use `| raw` for user-provided or unsanitised strings.
- Do not expect `render()` alone to emit styles, scripts, images, or runtime files. Use `renderResult()` when your host needs resources.
- Do not put every interaction into `@script`. Use `@state` and event actions first when the behaviour is local and declarative.
