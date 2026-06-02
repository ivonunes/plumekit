# Plume for VS Code

Adds editor support for Plume templates:

- Syntax highlighting for `.plume` files.
- Snippets for common directives and components.
- Formatting, diagnostics, completions, and document symbols through `plume language-server` or `inkstead-writer theme language-server`.
- A `Plume: Check Templates` command that runs `plume check`, or `inkstead-writer theme check` inside an Inkstead Writer site.

The extension prefers a workspace-local `./inkstead-writer` launcher for Inkstead Writer sites, then falls back to `plume` on `PATH`. Set `plume.toolPath` when you want to use a specific binary.

Release builds are published as `.vsix` files on the Plume GitHub release.
