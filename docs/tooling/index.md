# Tooling

Plume ships a small CLI for checking, formatting, and editor integration. The CLI is useful for standalone Plume users and for editor extensions.

Inkstead Writer embeds Plume, so Writer sites usually run the same capabilities through `inkstead-writer theme ...`.

If you need the standalone CLI first, see [Start](../start/getting-started.md).

## Commands

Check templates:

```sh
plume check
plume check theme
plume check theme/home.plume
```

Format templates:

```sh
plume format theme
plume format --check theme
```

Format stdin for editor integrations:

```sh
cat template.plume | plume format --stdin
```

Run the language server:

```sh
plume language-server
```

Print the Plume version:

```sh
plume version
```

## Feedback

While writing templates, run `check` when you want diagnostics and `format` when you want the file rewritten:

```sh
plume check theme
plume format theme
```

In CI, use `format --check` so the build fails when committed templates are not formatted:

```sh
plume format --check theme
```

## Checks

`plume check` validates:

- Template syntax.
- Component calls and component arguments.
- Named slot content placement.
- Inline Plume client scripts.
- Static style and script file references.
- Static asset and image references the host can see.

Inkstead Writer adds Writer-specific checks for theme paths, generated images, missing image alt text, and site context.

## Writer

Inside a Writer site, prefer the site-local wrapper:

```sh
./inkstead-writer theme check
./inkstead-writer theme format
./inkstead-writer theme format --check
./inkstead-writer theme language-server
```

This uses the Plume version embedded in the Writer version pinned by the site.

## Editors

VS Code and Nova extensions are packaged with each Plume release.

They provide:

- Syntax highlighting.
- Snippets.
- Diagnostics.
- Formatting.
- Directive and context completions.
- Document symbols.

The extensions prefer a site-local `./inkstead-writer` wrapper when available. Outside Writer sites, they fall back to the standalone `plume` command on `PATH`.

## Troubleshooting

If diagnostics or formatting do not appear:

- Confirm `plume language-server` runs in a terminal.
- In an Inkstead Writer site, confirm `./inkstead-writer theme language-server` runs from the site root.
- Run `plume check path/to/file.plume` to separate editor setup issues from template errors.
- Make sure the editor extension can see either the site-local Writer wrapper or the standalone `plume` command on `PATH`.
