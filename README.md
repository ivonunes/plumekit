# Plume

Plume is a templating language for building expressive websites. It brings HTML, styles, assets, and behaviour into one coherent authoring model, with components, scoped styles, responsive media, build-time checks, and lightweight interactivity designed to feel clear, calm, and close to the web.

This package contains:

- The `Plume` Swift module.
- The Plume parser, renderer, formatter, checker, and client-script compiler.
- `PlumeLanguageServer`, used by editor integrations.
- A standalone `plume` CLI for formatting, checking, and language-server support.
- VS Code and Nova extensions under `editors/`.
- A documentation tree under `docs/`.

## Install

Install the standalone CLI with Homebrew:

```sh
brew tap ivonunes/tap
brew install plume
```

Or use the installer:

```sh
curl -fsSL https://install.inkstead.dev/plume | sh
```

You can also embed Plume in a Swift package:

```swift
.package(url: "https://github.com/ivonunes/plume", from: "1.0.0")
```

```swift
.product(name: "Plume", package: "plume")
```

## Development

```sh
swift test
```

Editor integrations can launch the language server directly:

```sh
plume language-server
```

Inkstead Writer embeds Plume and exposes `inkstead-writer theme language-server` as a bridge for site-local wrappers.

The VS Code and Nova extensions are packaged as release artifacts. They prefer a site-local `./inkstead-writer` wrapper inside Writer projects, then fall back to the standalone `plume` command on `PATH`.

## Documentation

The docs are published under `inkstead.dev/plume` and live in `docs/`. They are organised around Start, Syntax, Components, Customise, Embedding, and Tooling.

- [Start](docs/start/getting-started.md): install the CLI, write a first template, check it, and format it.
- [Syntax](docs/syntax/index.md): output, expressions, conditionals, loops, filters, methods, and attributes.
- [Components](docs/components/index.md): component APIs, defaults, slots, named slots, composition, and loading.
- Customise: [Resources](docs/customise/resources.md) covers styles, scripts, assets, and images; [Behaviour](docs/customise/behaviour.md) covers state, actions, browser helpers, scripts, and navigation.
- [Embedding](docs/embedding/index.md): Swift APIs, render results, resources, runtime, and host responsibilities.
- [Tooling](docs/tooling/index.md): CLI commands, editor support, checks, CI formatting, and troubleshooting.
