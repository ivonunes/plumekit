# Embedding Plume

Plume is a Swift package. Host applications provide templates, context values, functions, components, and resource handling.

## Render A Template

The core API is `PlumeTemplate`:

```swift
import Plume

let template = try PlumeTemplate("""
<h1>{site.title}</h1>
""")

let html = try template.render([
    "site": ["title": "My Site"]
])
```

Use `render` when you only need HTML.

Use `sourceName` when you have one. Diagnostics, editor tooling, scoped resources, and host-side file resolution are easier to understand when Plume knows which file is being rendered:

```swift
let template = try PlumeTemplate(
    source,
    sourceName: "theme/pages/home.plume"
)
```

## Render With Resources

Use `renderResult` when the host needs collected styles, scripts, state, images, or navigation declarations:

```swift
let result = try template.renderResult(context)

print(result.html)
print(result.styles)
print(result.scripts)
print(result.state)
print(result.navigation)
print(result.requiresRuntime)
```

The host decides how resources are emitted. Inkstead Writer turns collected styles and scripts into fingerprinted files, emits responsive images, and injects runtime scripts only when needed.

Use `renderResult` for any template that may contain `@style`, `@script`, `@image`, `@state`, event bindings, or `@navigation`.

## Components

Pass component sources into the template environment:

```swift
let environment = try PlumeTemplateEnvironment(componentSources: [
    "components/PostCard.plume": postCardSource,
    "components/PageSection.plume": pageSectionSource
])

let template = try PlumeTemplate(
    source,
    sourceName: "home.plume",
    environment: environment
)
```

Components defined inside the current template are collected automatically.

## Safe HTML

Ordinary strings are escaped. Use `PlumeSafeHTML` for trusted HTML that the host has already rendered or sanitized:

```swift
let html = try template.render([
    "content": PlumeSafeHTML("<p>Rendered Markdown</p>")
])
```

```plume
<article>{content}</article>
```

## Functions

Host applications can expose functions:

```swift
let html = try template.render([
    "asset": PlumeFunction { call in
        guard let path = call.arguments.first as? String else {
            return ""
        }
        return "/assets/" + path
    }
])
```

Templates call the function like any other expression:

```plume
<link rel="stylesheet" href="{asset('site.css')}">
```

Use functions for host-specific behaviour such as asset resolution, URL generation, image helpers, or formatting values that should remain outside the template language.

## Diagnostics And Editor Support

Use `PlumeLanguageSupport` for editor-facing tooling:

```swift
let diagnostics = PlumeLanguageSupport.diagnostics(
    for: source,
    sourceName: "theme/home.plume",
    componentSources: components
)
```

The standalone language server and editor extensions use the same language support APIs.

## Minimal Host Shape

A small host usually needs these pieces:

- A loader for template source files.
- A loader for component source files.
- A context builder that turns application data into dictionaries, arrays, strings, numbers, booleans, and `PlumeSafeHTML`.
- Host functions such as `asset()`.
- A resource emitter for collected styles, scripts, images, and runtime files.

Start with `render()` while prototyping. Move to `renderResult()` when templates begin declaring resources or interactivity.

## Host Responsibilities

Plume renders templates and records resource declarations. A host application is responsible for:

- Loading templates and component sources.
- Supplying context data.
- Marking trusted HTML as `PlumeSafeHTML`.
- Providing functions such as `asset()`.
- Resolving `@style(file:)`, `@script(file:)`, and `@image` references.
- Emitting collected styles and scripts.
- Emitting the runtime when `requiresRuntime` is true.
