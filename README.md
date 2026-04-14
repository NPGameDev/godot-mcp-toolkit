# Godot MCP Toolkit

A Godot 4.4+ editor plugin that hosts a localhost (`127.0.0.1:6505`) WebSocket
server so Claude Code — or any MCP-compatible client — can drive scene, node,
script, and editor operations directly inside the Godot editor. Pairs with
the companion [`godot-mcp-server`](https://github.com/NPGameDev/godot-mcp-server)
npm package (TypeScript, stdio-to-WebSocket bridge).

## How the two pieces fit

```
Claude Code ── stdio ──▶ godot-mcp-server (npm, Node.js) ── ws://127.0.0.1:6505 ──▶ godot_mcp_toolkit (this plugin, inside the Godot editor)
```

Users install both: the plugin via Godot's AssetLib (once submitted) or the
manual zip route, and the server via `npm install -g godot-mcp-server`.

## Install

- **End users**: see [`DISTRIBUTION.md`](./DISTRIBUTION.md) — covers the
  AssetLib route, the manual-zip route, and the `.mcp.json` placement step.
- **Developers / dogfood** (this repo itself): see the "Dogfood setup" section
  below.

> ⚠️ No releases have been tagged yet. The first public release is gated
> to iteration 20 in the planning repo (adds transport auth, filesystem
> sandbox, response caps, secret scrubbing, audit log). Pre-iter-20 use is
> internal dogfood only. See `DISTRIBUTION.md` for the gate rationale.

## Dogfood setup

This repo root **is** a Godot 4.4 project (`project.godot` at root,
`addons/godot_mcp_toolkit/` at root). Opening it in Godot is the test
environment for the plugin.

```
# one-time, in the companion server repo
cd <godot-mcp-server repo root>
npm install && npm run build && npm link

# every session
# 1) open THIS repo root in Godot 4.4+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from THIS repo root (where .mcp.json lives):
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10 tools.
```

`.mcp.json` is configured to run `npx godot-mcp-server`, so `npm link` alone
is enough to dogfood changes to the server — no `.mcp.json` edits required.

Windows-first: `.mcp.json` uses `cmd /c npx godot-mcp-server`. On Linux / macOS,
drop the `cmd /c` wrapper (update the `command` + `args` in `.mcp.json`).

## Layout

- `addons/godot_mcp_toolkit/` — the plugin. This is what the AssetLib zip
  contains (and only this).
- `project.godot`, `icon.svg`, `icon.png`, `Main.tscn` — the dogfood Godot
  project at the repo root.
- `.mcp.json` — live Claude Code dogfood config. Kept byte-identical to
  `addons/godot_mcp_toolkit/.mcp.json.template` (the copy shipped via
  AssetLib for end users to promote into their own project root).
- `scripts/build-plugin-release.{sh,ps1}` — build the AssetLib zip from
  `addons/godot_mcp_toolkit/`.
- `DISTRIBUTION.md` — release process + AssetLib submission checklist +
  security gate.
- `CLAUDE.md` — user-facing Claude Code conventions for driving the 10 MCP
  tools.
- `ATTRIBUTIONS.md` — upstream notices for studied reference projects.

## Tool catalogue (10, iter 08)

`scene_get_tree`, `scene_create_node`, `scene_delete_node`,
`node_get_property`, `node_set_property`, `script_read`, `script_write`,
`editor_get_errors`, `editor_save_scene`, `editor_screenshot`.

See [`CLAUDE.md`](./CLAUDE.md) for one-line descriptions and calling
conventions.

## Port

`127.0.0.1:6505` — localhost-only bind (never `0.0.0.0`). Override with the
`GODOT_MCP_PORT` env var on the server side.

## Status

MVP (iteration 08 of 26). Full execution plan (toolkit + server):
<https://github.com/NPGameDev/godot-mcp-creation> → `Plan/ExecutionPlan/00-index.md`.

## Licence

MIT — see [`LICENSE`](./LICENSE). Upstream notices in
[`ATTRIBUTIONS.md`](./ATTRIBUTIONS.md).
