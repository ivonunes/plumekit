# Tooling

The `plumekit` CLI provides Plume's templating commands: checking, formatting, compiling and editor integration. This page covers those commands and the editor extensions that build on them.

For the full command list (including `serve`, `dev`, `migrate`, `deploy` and `generate`) and the `plumekit.toml` reference, see [CLI & configuration](../cli.md). If you need to install the CLI first, see [Start](../start/getting-started.md).

## Checking templates

Run `plumekit check` on a project, a directory or a single file:

```sh
plumekit check
plumekit check theme
plumekit check theme/home.plume
```

`plumekit check` validates:

- Template syntax.
- Component calls and component arguments.
- Named slot content placement.
- Inline Plume client scripts.
- Static style and script file references.
- Static asset and image references the host can see.

## Formatting templates

Run `plumekit format` to rewrite templates in place, or `--check` to report without rewriting:

```sh
plumekit format theme
plumekit format --check theme
```

While writing templates, run `check` when you want diagnostics and `format` when you want the file rewritten.

### Canonical spellings

Formatting also canonicalises alias spellings to one Swift-spelled name per transform, for example `upcase` to `uppercased`, `startsWith` to `hasPrefix`, `null` to `nil` and `@slot(name: x)` to `@slot(x)`. Both spellings keep parsing; the formatter rewrites to the canonical one. String-literal contents are left untouched.

### Formatting from stdin

Format stdin for editor integrations:

```sh
cat template.plume | plumekit format --stdin
```

### Formatting in CI

In CI, use `format --check` so the build fails when committed templates are not formatted:

```sh
plumekit format --check theme
```

## Compiling templates

Compile templates to Embedded-Swift render functions (the compiling back-end):

```sh
plumekit compile Views/                 # print generated Swift to stdout
plumekit compile Views/ -o Generated/   # write one .swift per template
```

See [Compiling templates](../compiling/index.md) for the renderable subset and the build-time-only features it rejects.

## The language server

Run the language server:

```sh
plumekit language-server
```

## Printing the version

Print the version:

```sh
plumekit version
```

## Editors

VS Code and Nova extensions are packaged with each PlumeKit release.

They provide:

- Syntax highlighting.
- Snippets.
- Diagnostics.
- Formatting.
- Directive and context completions.
- Document symbols.

The extensions use the `plumekit` command on `PATH`.

## Troubleshooting

If diagnostics or formatting do not appear:

- Confirm `plumekit language-server` runs in a terminal.
- Run `plumekit check path/to/file.plume` to separate editor setup issues from template errors.
- Make sure the editor extension can see the `plumekit` command on `PATH`.
