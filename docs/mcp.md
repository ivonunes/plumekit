# MCP server for AI agents

The `plumekit` CLI ships an **MCP server** that gives AI coding agents (Claude Code,
Codex, OpenCode, …) accurate, structured access to PlumeKit (its APIs, your project's
configuration, and the docs) so they write correct code.

## What it provides

`plumekit mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io)
over stdio and exposes these tools:

- **`api_reference(topic)`**: an accurate, embedded reference for a core API. Topics:
  `overview`, `routing`, `request`, `response`, `orm`, `migrations`, `forms`, `views`,
  `capabilities`, `i18n`, `schedule`, `helpers`, `testing`, `cli`, `config`, `portability`
  (the Embedded-Wasm rules for code you write). The agent should call this *before*
  writing PlumeKit code.
- **`project_info()`**: the current project's `plumekit.toml` (enabled capabilities,
  targets, build/deploy config).
- **`search_docs(query)`**: searches the framework documentation.

Run it from your project root (so `project_info` finds `plumekit.toml`), and use the
committed **`./plumekit` wrapper** so the agent works at the version your app builds
against.

## Setup

The MCP config format differs per agent, but each just runs `./plumekit mcp` as a
stdio server. (Config keys evolve; if one of these is out of date, check the agent's
own MCP documentation; the command to run is always `./plumekit mcp`.)

### Claude Code

Add it with the CLI:

```sh
claude mcp add plumekit -- ./plumekit mcp
```

or commit a project-scoped `.mcp.json` (shared with your team):

```json
{
  "mcpServers": {
    "plumekit": { "command": "./plumekit", "args": ["mcp"] }
  }
}
```

### Codex

Add an MCP server to `~/.codex/config.toml`:

```toml
[mcp_servers.plumekit]
command = "./plumekit"
args = ["mcp"]
```

### OpenCode

Add a local MCP server to `opencode.json` (project root, or `~/.config/opencode/`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "plumekit": {
      "type": "local",
      "command": ["./plumekit", "mcp"],
      "enabled": true
    }
  }
}
```

### Any other MCP client

Any agent that supports MCP stdio servers can run `./plumekit mcp` (or `plumekit mcp`
if the CLI is on your PATH). Point it at that command per the agent's MCP config.

## Getting the most from it

- Tell the agent to **use `api_reference` for PlumeKit APIs before writing code**; it
  keeps generated code accurate. A good project instruction (e.g. in `AGENTS.md` /
  `CLAUDE.md`): *"This is a PlumeKit app. Use the plumekit MCP `api_reference` tool for
  its APIs before writing code."*
- Run the agent from the **project root** so `project_info` finds `plumekit.toml`.
  (`api_reference` and `search_docs` work anywhere — the docs are embedded in the
  binary, so no framework checkout is needed.)
- Pair it with the [tutorial](start/tutorial.md) and [CLI reference](cli.md) for
  humans on the team.
