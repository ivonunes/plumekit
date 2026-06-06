# Getting Started

Plume is a templating language for building expressive websites. It keeps markup, components, styles, assets, and small interactions close together, so the page you write stays close to the page you ship.

A Plume file is mostly HTML. Plume adds expressions, directives, components, and resource declarations where plain HTML needs help.

This guide shows the quickest path from a blank template to a checked and formatted file.

## What Plume Gives You

- Escaped output by default.
- Clear control flow with `@if`, `else if`, `else`, `@for`, and `@let`.
- Components with named arguments, defaults, slots, and named slot content.
- Attribute helpers for conditional classes, optional attributes, and style bindings.
- Co-located `@style`, `@script`, `asset()`, and `@image` usage.
- Small interactive behaviours through state, event bindings, browser actions, and page navigation.
- Formatting, checking, language server support, and editor extensions.

## Choose Entry Point

Use the standalone `plume` CLI when you are embedding Plume in your own project, experimenting with the language, or wiring up editor support outside Inkstead Writer.

Use the site-local `./inkstead-writer` wrapper inside an Inkstead Writer site. Writer embeds the Plume version that belongs to that site, so the theme commands are the safest way to check and format Writer themes.

## Install

Install with Homebrew:

```sh
brew tap ivonunes/tap
brew install plume
```

Or use the installer:

```sh
curl -fsSL https://install.inkstead.dev/plume | sh
```

Inkstead Writer users can use the site-local wrapper instead:

```sh
./inkstead-writer theme check
./inkstead-writer theme format
```

## First Template

Create `home.plume`. A first template can be normal HTML with a few expressions and directives:

```plume
<h1>{site.title}</h1>

@if posts.size > 0 {
  <ul>
    @for post in posts {
      <li>
        <a href="{post.urlPath}">{post.title | default("Untitled")}</a>
      </li>
    }
  </ul>
} else {
  <p>No posts yet.</p>
}
```

Run a check:

```sh
plume check home.plume
```

Format it:

```sh
plume format home.plume
```

## Mental Model

Plume has a few core rules:

- `{expression}` prints escaped output.
- Trusted HTML must come from the host as `PlumeSafeHTML` or be explicitly marked with `| raw`.
- Directives start with `@`, such as `@if`, `@for`, `@component`, `@style`, and `@script`.
- Components are called with PascalCase names, such as `@PostCard(post)`.
- Styles, scripts, images, and assets are collected while rendering so the host can emit them as real site resources.

The host provides the data. In the example above, `site`, `posts`, and `post.urlPath` are not global Plume objects; they come from the application rendering the template. Inkstead Writer provides those values for themes, while another Swift host can provide a completely different context.

When you are unsure where something belongs, start with HTML first. Add Plume only where it removes repetition, clarifies conditional output, keeps resources close to their markup, or avoids custom JavaScript for small interactions.

## Next

Read [Syntax](../syntax/index.md) for the language reference, [Components](../components/index.md) for reusable markup, and [Embedding](../embedding/index.md) when you want to use Plume from Swift.
