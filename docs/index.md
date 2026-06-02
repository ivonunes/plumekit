# Plume

Plume is a templating language for building expressive websites. It keeps markup, components, styles, assets, and small interactions close together, so the page you write stays close to the page you ship.

It is designed for sites where HTML still matters, but where plain template files start to feel too scattered once you add components, responsive images, scoped styles, editor tooling, and a little behaviour.

```plume
@component PostCard(post) {
  @style(scoped) {
    .card {
      display: grid;
      gap: 0.75rem;
    }
  }

  <article class="card">
    <h2><a href="{post.urlPath}">{post.title | default("Untitled")}</a></h2>
    {post.excerpt}
  </article>
}

@for post in posts {
  @PostCard(post)
}
```

## What It Gives You

- Readable templates with escaped output by default.
- Components with named arguments, defaults, slots, and named content.
- Clear control flow with `@if`, `else if`, `else`, `@for`, and `@let`.
- Attribute helpers for conditional classes, optional attributes, and style bindings.
- Colocated `@style`, `@script`, `asset()`, and `@image` usage that hosts can collect and emit properly.
- Small interactive islands through state, event bindings, browser actions, and page navigation hooks.
- Formatting, checking, language server support, and editor extensions.

If you work in Swift or SwiftUI, parts of Plume will feel familiar: named arguments, tidy control flow, colocated structure, and a bias toward readable composition.

## Where Plume Fits

Plume is a Swift package and can be embedded in other Swift applications. It is also available as a standalone CLI for checking, formatting, and editor support.
