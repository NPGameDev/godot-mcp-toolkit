# Godot MCP Toolkit

Godot 4.x editor plugin that runs a localhost (`127.0.0.1:6505`) WebSocket server so Claude Code — or any MCP-compatible client — can drive scene / node / script operations directly inside the Godot editor.

## Layout

- `addons/godot_mcp_toolkit/` — the plugin, distributed standalone via Godot AssetLib as a single zip.
- `project.godot` — this repo root doubles as the **dogfood** Godot project. Opening the repo root in Godot 4.x gives you a working environment to develop and test the plugin.
- `.mcp.json` — live Claude Code dogfood MCP config at repo root. Kept byte-identical to `addons/godot_mcp_toolkit/.mcp.json.template` (the copy shipped via AssetLib for end users).
- `icon.svg` / `icon.png` — Godot project icon and AssetLib thumbnail placeholders.

## Port

`127.0.0.1:6505` — localhost-only bind; never `0.0.0.0`.

## Companion bridge

The TypeScript MCP server lives in a **separate sibling repo** and ships via npm:

```
npm install -g godot-mcp-server
```

Source: <https://github.com/NPGameDev/godot-mcp-server>

Both pieces are needed for the full stack: the toolkit plugin (here) talks to the server, the server talks to Claude Code.

## Status

Iteration 01a (scaffold). The full execution plan — 26 iterations across toolkit + server — lives in the sibling planning repo: <https://github.com/NPGameDev/godot-mcp-creation> → `Plan/ExecutionPlan/00-index.md`.
