# Plume for VS Code

Adds editor support for Plume templates:

- Syntax highlighting for `.plume` files.
- Snippets for common directives and components.
- Formatting, diagnostics, completions, and document symbols through `plumekit language-server`.
- A `Plume: Check Templates` command that runs `plumekit check`.

The extension uses a workspace-local `./plumekit` wrapper when present, then falls back to `plumekit` on `PATH`. Set `plume.toolPath` to point at a specific binary.

Release builds are published as `.vsix` files on the PlumeKit GitHub release.
