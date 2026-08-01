# MCP server for AI agents

The `plumekit` CLI ships an **MCP server** for AI coding agents (Claude Code, Codex, OpenCode and others). It gives them accurate, structured access to PlumeKit: the framework APIs, your project's configuration and the docs, so they write correct code instead of guessing.

## What it provides

`plumekit mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over stdio and exposes three tools:

| Tool | What it returns |
| --- | --- |
| `api_reference(topic)` | An accurate, embedded reference for a core API. |
| `project_info()` | The current project's `plumekit.toml`: enabled capabilities, targets, build/deploy config. |
| `search_docs(query)` | Search results from the framework documentation. |

`api_reference` covers these topics: `overview`, `routing`, `request`, `response`, `orm`, `migrations`, `forms`, `views`, `capabilities`, `i18n`, `schedule`, `helpers`, `testing`, `cli`, `config` and `portability` (the Embedded-Wasm rules for code you write). The agent should call it *before* writing PlumeKit code.

Run the server from your project root, so `project_info` finds `plumekit.toml`, and use the committed [`./plumekit` wrapper](cli.md#the-plumekit-wrapper) so the agent works at the version your app builds against.

## Setup

The MCP config format differs per agent, but each one just runs `./plumekit mcp` as a stdio server.

> **Note:** Config keys evolve. If one of these examples is out of date, check the agent's own MCP documentation; the command to run is always `./plumekit mcp`.

### Claude Code

Add it with the CLI:

```sh
claude mcp add plumekit -- ./plumekit mcp
```

or commit a project-scoped `.mcp.json`, shared with your team:

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

Any agent that supports MCP stdio servers can run `./plumekit mcp` (or `plumekit mcp` if the CLI is on your PATH). Point it at that command per the agent's MCP config.

## Getting the most from it

- Tell the agent to **use `api_reference` for PlumeKit APIs before writing code**; it keeps generated code accurate. A good project instruction (in `AGENTS.md` or `CLAUDE.md`): *"This is a PlumeKit app. Use the plumekit MCP `api_reference` tool for its APIs before writing code."*
- Run the agent from the **project root** so `project_info` finds `plumekit.toml`. `api_reference` and `search_docs` work anywhere: the docs are embedded in the binary, so no framework checkout is needed.
- Pair it with the [tutorial](start/tutorial.md) and [CLI reference](cli.md) for the humans on the team.
