# CLAUDE.md — godot-mcp-toolkit

Guidance for Claude Code (claude.ai/code) **when driving this Godot project via
MCP tools**. If you are editing the toolkit's GDScript source instead, the tool
list is the same but the conventions in this file are most useful to agents
calling tools, not to agents changing the plugin's internals.

(If you are editing the TypeScript bridge, see the sibling
[`godot-mcp-server`](https://github.com/NPGameDev/godot-mcp-server) repo's
`CLAUDE.md`.)

---

## What this plugin does

Runs a localhost WebSocket server (`127.0.0.1:6505`) inside the Godot editor
and exposes scene, node, script, and editor operations to any MCP client (e.g.
Claude Code via the companion `godot-mcp-server` npm package).

## MVP tool catalogue (10 tools — iter 08)

| Tool                    | One-liner                                                                        |
|-------------------------|----------------------------------------------------------------------------------|
| `scene_get_tree`        | Return the edited scene as nested JSON `{ name, class, path, children }`.        |
| `scene_create_node`     | Create `class_name` under `parent`. Idempotent — returns existing path on collision. |
| `scene_delete_node`     | Delete node at `path`. UndoRedo-based; refuses to delete the edited-scene root.  |
| `node_get_property`     | Read a property. Engine types (Vector2, Color, …) come back dict-wrapped.        |
| `node_set_property`     | Write a property. Pass engine types as `{ type: "Vector2", x: 0, y: 0 }`.        |
| `script_read`           | Read a GDScript / text file (`res://` only).                                     |
| `script_write`          | Write a GDScript / text file (`res://` only). Overwrites.                        |
| `editor_get_errors`     | Return recent compile / runtime errors (MVP stub; iter 10 replaces).             |
| `editor_save_scene`     | Save the current edited scene. Optional `path` → save-as.                        |
| `editor_screenshot`     | Capture the editor viewport; returns inline image content (+ optional `save_path`). |

## Conventions when driving these tools

- **Paths always use `res://`.** No absolute filesystem paths. Until iter 18
  installs `FileGuard`, the plugin accepts `res://` and rejects the rest.
- **GDScript filenames are `snake_case`**, e.g. `res://player_controller.gd`.
- **After node mutations, call `editor_save_scene`.** Without it, changes stay
  in memory and are lost on editor close.
- **After `script_write`, call `editor_get_errors`.** Lets you catch syntax
  issues before trusting the file.
- **The Godot editor with this plugin enabled must be running** — the bridge
  has no way to launch Godot for you. If `/mcp` shows the server as
  disconnected, check Project Settings → Plugins → "Godot MCP Toolkit".
- **Idempotency:** every `create_*` returns the existing path with
  `code: "ALREADY_EXISTS"` on collision (treated as success). Safe to retry.

## Dogfood setup (this repo)

This repo root IS a Godot 4.4 project (`project.godot` at root,
`addons/godot_mcp_toolkit/` at root). The `.mcp.json` at repo root is the live
Claude Code config — it runs `npx godot-mcp-server`.

```
# one-time
cd <godot-mcp-server-repo>
npm install && npm run build && npm link

# every session
# 1) open this repo root in Godot 4.4+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from this repo root:
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10 tools.
```

## End-user install

See [`DISTRIBUTION.md`](./DISTRIBUTION.md) — covers the AssetLib route, the
manual-zip route, and the server-side `npm install -g` step.

## Pointer

Execution plan (all 26 iterations, cross-repo):
`<plan-repo>/Plan/ExecutionPlan/00-index.md`.
