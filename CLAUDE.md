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
Claude Code via the companion `@npgamedev/godot-mcp-server` npm package).

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
`addons/godot_mcp_toolkit/` at root). The `.mcp.json` at repo root points at a
locally-built server bridge.

**Pre-iter-20 note.** Because `@npgamedev/godot-mcp-server` is not yet
published to npm, the dogfood `.mcp.json` uses a path-based
`node <abs-path>/dist/index.js` invocation rather than the scoped
`npx -y @npgamedev/godot-mcp-server` form that end users will use
post-iter-20. The template at `addons/godot_mcp_toolkit/.mcp.json.template`
is kept byte-identical to the root `.mcp.json` through both states (see iter
13b + iter 20's swap-back verification).

**Do not launch `claude` from this repo root.** Godot 4.4.1 has an observed
crash when the plugin is enabled in the dogfood project — see the plan
repo's `Plan/Reports/2026-04-15-godot-44-tcpserver-crash-dogfood.md` and
`memory/project_dogfood_pattern.md`. Use the sibling
`godot-mcp-dogfood-playground/` project for day-to-day dogfooding instead.

```
# one-time
cd <server-repo>
npm install && npm run build

# every session, in the playground project (NOT this repo root)
# 1) open the playground in Godot 4.4+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from the playground root:
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10+ tools.
```

## End-user install

See [`DISTRIBUTION.md`](./DISTRIBUTION.md) — covers the AssetLib route, the
manual-zip route, and the server-side `npm install -g` step.

## Pointer

Execution plan (all 26 iterations, cross-repo):
`<plan-repo>/Plan/ExecutionPlan/00-index.md`.
