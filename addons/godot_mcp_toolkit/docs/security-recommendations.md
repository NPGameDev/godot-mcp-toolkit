# Security Recommendations

This document describes which MCP tools carry risk, how to restrict them
using your AI agent's built-in filtering, and how to enable the toolkit's
read-only mode for supervised environments.

## High-risk tools

These six tools warrant consideration for per-tool blocking depending on
your trust model:

| Tool | Risk | Why you might block it | Side effect of blocking |
|---|---|---|---|
| `execute_code` | Executes arbitrary GDScript via Expression | Prevents agent from running unconstrained code at runtime | Agent loses ability to test game logic dynamically, inspect runtime state via expressions |
| `node_call_method` | Calls any method on any scene node | Prevents agent from invoking undocumented/dangerous methods | Agent can't call custom methods on nodes --- must use dedicated tools instead |
| `save_write` | Writes to `user://` persistent storage | Prevents agent from modifying player saves/config | Agent can't create or update save files, config, preferences |
| `save_delete` | Deletes from `user://` | Prevents accidental save data loss | Agent can't clean up test saves or obsolete config |
| `save_read` | Reads `user://` persistent data | Prevents access to potentially sensitive player data | Agent can't inspect save file contents (can still read via filesystem if agent is not sandboxed) |
| `save_list` | Lists `user://` directory contents | Prevents discovery of save file structure | Agent can't enumerate what's stored (can still `ls` via filesystem if agent is not sandboxed) |

Any tool with a `destructiveHint` MCP annotation modifies project assets or
state. Many of these support Undo (Ctrl+Z in the editor reverts their changes).

## Built-in read-only mode

For users who want a read-only session without configuring per-tool blocking,
`GODOT_MCP_READ_ONLY=1` is the simplest option. Set it in `.mcp.json` `env`
and all tools annotated with `destructiveHint` are hidden from the agent ---
this covers arbitrary code execution (`execute_code`), node method calls
(`node_call_method`), user-folder writes (`save_write`, `save_delete`), and
every other mutating tool.

**What it does NOT block:** read-only tools like `save_read` and `save_list`
remain visible. The agent can still inspect save file contents and directory
structure (and could also read those paths via its own native filesystem
access if unsandboxed).

```jsonc
// .mcp.json -- env block
{
  "env": {
    "GODOT_MCP_READ_ONLY": "1"
  }
}
```

For finer-grained control (e.g., allow mutations but block only
`execute_code`), use the per-tool agent-side filtering below.

## Per-tool agent-side blocking

### Claude Code

`.claude/settings.json` permissions system:

```json
{
  "permissions": {
    "deny": [
      "mcp__godot-mcp__execute_code",
      "mcp__godot-mcp__node_call_method"
    ]
  }
}
```

Pattern: `mcp__<server-name>__<tool-name>`. Wildcards supported:
`mcp__godot-mcp__save_*` blocks all save tools. Deny rules take precedence
over allow at all levels.

### Google Gemini CLI

`~/.gemini/config.json` (or project-level):

```json
{
  "mcpServers": {
    "godot-mcp": {
      "excludeTools": [
        "execute_code",
        "node_call_method",
        "save_write",
        "save_delete"
      ]
    }
  }
}
```

`excludeTools` always takes precedence over `includeTools`.

### OpenAI Codex / Agents SDK

Python code, tool filter at server init:

```python
from agents.mcp import MCPServerStdio, create_static_tool_filter

server = MCPServerStdio(
    params={"command": "godot-mcp-server"},
    tool_filter=create_static_tool_filter(
        blocked_tool_names=["execute_code", "node_call_method"]
    ),
)
```

Supports both `allowed_tool_names` (allowlist) and `blocked_tool_names`
(blocklist). Also supports async context-aware filter functions.

### Cursor

As of 2026-05-27, Cursor supports MCP tool filtering via **Hooks**
(programmatic scripts that intercept tool calls and return allow/deny/warn).
This requires more setup than Claude Code's or Gemini's declarative config.
Cursor also has `permissions.json` for auto-run allowlists (controls approval
flow, not blocking). No simple declarative `excludeTools`-style config exists
yet. Check Cursor's latest docs for updates, as this is an actively evolving
area.

### General guidance

For other MCP-compatible agents, consult their documentation for tool
filtering. Look for allowlist/blocklist/disallow/exclude mechanisms. The MCP
protocol exposes `destructiveHint` and `readOnlyHint` annotations per tool ---
well-behaved clients should prompt for confirmation on destructive operations.
