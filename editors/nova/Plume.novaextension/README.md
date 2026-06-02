# Plume for Nova

Adds Nova support for Plume templates:

- `.plume` syntax detection and highlighting.
- Indentation and bracket rules for Plume blocks.
- Diagnostics, completions, document symbols, and formatting through `plume language-server` or `inkstead-writer theme language-server`.
- Extension commands for restarting the language server and running `plume check`, or `inkstead-writer theme check` inside an Inkstead Writer site.

The extension prefers a workspace-local `./inkstead-writer` launcher for Inkstead Writer sites, then falls back to `plume` on `PATH`. Set `plume.toolPath` when you want to use a specific binary.

Release builds are published as zipped `.novaextension` bundles on the Plume GitHub release.
