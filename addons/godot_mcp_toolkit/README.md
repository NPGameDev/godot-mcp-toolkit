# Godot MCP Toolkit

Godot 4.4+ editor plugin that runs a localhost (`127.0.0.1:6505`) WebSocket
server so Claude Code (or any MCP-compatible client) can drive scene, node,
script, and editor operations inside the Godot editor.

## Install

**Via Godot Asset Library** (once the plugin is submitted — gated to iter 20):
AssetLib tab → search "Godot MCP Toolkit" → Download → Install.

**Via manual zip**: download the latest `godot-mcp-toolkit-*.zip` from the
[GitHub releases](https://github.com/NPGameDev/godot-mcp-toolkit/releases)
of the toolkit repo and extract into `<your-godot-project>/addons/`.

Then enable it: Project Settings → Plugins → tick **Godot MCP Toolkit**.

## Companion bridge (required)

The plugin is half the stack. You also need the TypeScript MCP server that
pipes stdio (Claude Code) to the plugin's WebSocket:

```
npm install -g @npgamedev/godot-mcp-server
```

Requires Node.js ≥ 20. Source + README:
<https://github.com/NPGameDev/godot-mcp-server>

## Connect Claude Code

1. Copy `addons/godot_mcp_toolkit/.mcp.json.template` up one level into your
   Godot project's root (same folder as `project.godot`) and rename it to
   `.mcp.json`.
2. `cd` to that project root.
3. Run `claude`. `/mcp` should list `godot-mcp-toolkit` with 10 tools
   connected.

(Iter 21 will add a one-click menu item in the editor's MCP dock that writes
`.mcp.json` for you.)

## Port

`127.0.0.1:6505` — localhost-only bind. Override by setting `GODOT_MCP_PORT`
on the server-side env.

## Minimum Godot version

Godot 4.4+. See the [repo-root README](../../README.md) for the full stack
overview and dogfood workflow.

## Licence

MIT — see `LICENSE` at the repo root. Upstream architectural references are
credited in `ATTRIBUTIONS.md` at the repo root.
