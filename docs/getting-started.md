# Getting Started

A Plume file is mostly HTML. Plume adds expressions, directives, components, and resource declarations where plain HTML needs help.

This guide shows the quickest path from a blank template to a checked and formatted file.

## Choose Your Entry Point

Use the standalone `plume` CLI when you are embedding Plume in your own project, experimenting with the language, or wiring up editor support outside Inkstead Writer.

Use the site-local `./inkstead-writer` wrapper inside an Inkstead Writer site. Writer embeds the Plume version that belongs to that site, so the theme commands are the safest way to check and format Writer themes.

## Install The CLI

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

## Write A Template

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

## The Mental Model

Plume has a few core rules:

- `{expression}` prints escaped output.
- Trusted HTML must come from the host as `PlumeSafeHTML` or be explicitly marked with `| raw`.
- Directives start with `@`, such as `@if`, `@for`, `@component`, `@style`, and `@script`.
- Components are called with UpperCamelCase names, such as `@PostCard(post)`.
- Styles, scripts, images, and assets are collected while rendering so the host can emit them as real site resources.

The host provides the data. In the example above, `site`, `posts`, and `post.urlPath` are not global Plume objects; they come from the application rendering the template. Inkstead Writer provides those values for themes, while another Swift host can provide a completely different context.

When you are unsure where something belongs, start with HTML first. Add Plume only where it removes repetition, clarifies conditional output, keeps resources close to their markup, or avoids custom JavaScript for small interactions.

## Use It From Swift

Plume is also a Swift library:

```swift
import Plume

let template = try PlumeTemplate("""
<h1>{site.title}</h1>
""")

let html = try template.render([
    "site": ["title": "My Site"]
])
```

Output is escaped by default:

```swift
let html = try template.render([
    "title": "<script>alert('x')</script>"
])
```

```plume
<h1>{title}</h1>
```

When the host has already rendered trusted HTML, pass `PlumeSafeHTML`:

```swift
let html = try template.render([
    "content": PlumeSafeHTML("<p>Already rendered Markdown.</p>")
])
```

```plume
<article>{content}</article>
```

## Organise Files

Plume does not require a specific directory layout. Hosts decide how templates and components are loaded.

Inkstead Writer uses a layout like this:

```txt
theme/
  layouts/
    default.plume
  pages/
    home.plume
    post.plume
  components/
    PostCard.plume
  styles/
    site.css
  scripts/
    site.plume
```

For a standalone Plume project, keep templates and components wherever your host application expects them. The CLI can scan a folder:

```sh
plume check theme
plume format --check theme
```
