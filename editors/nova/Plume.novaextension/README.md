# Plume for Nova

Adds Nova support for Plume templates:

- `.plume` syntax detection and highlighting.
- Indentation and bracket rules for Plume blocks.
- Diagnostics, completions, document symbols, and formatting through `plumekit language-server`.
- Extension commands for restarting the language server and running `plumekit check`.

The extension uses a workspace-local `./plumekit` wrapper when present, then falls back to `plumekit` on `PATH`. Set `plume.toolPath` to point at a specific binary.

Release builds are published as zipped `.novaextension` bundles on the PlumeKit GitHub release.
