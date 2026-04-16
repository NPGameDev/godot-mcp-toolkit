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

## Core tool catalogue (13 MVP-core tools — iter 08 + iter 15)

Additional Tier 1–3 tools from iter 09–12 (`editor_reload_scripts`,
`scene_open`, `project_get_settings`, `signal_*`, `resource_load`,
`scene_diff`, `node_get_property_list`, and the Mode B `runtime_*` family)
bring the full catalogue to 28 tools (29 with `GODOT_MCP_ALLOW_GAME_EVAL=1`).
Pass `--lite` in `.mcp.json` args for a 16-tool token-sensitive subset.

| Tool                    | One-liner                                                                        |
|-------------------------|----------------------------------------------------------------------------------|
| `scene_get_tree`        | Return the edited scene as nested JSON `{ name, class, path, children }`.        |
| `scene_create_node`     | Create `class_name` under `parent`. Idempotent — `status: "returned"` on collision. |
| `scene_delete_node`     | Delete node at `path`. UndoRedo-based; refuses to delete the edited-scene root.  |
| `scene_create`          | Create `.tscn` file at `path` with root `root_type`. Idempotent; `if_exists: return\|fail\|replace`. |
| `scene_delete`          | Delete `.tscn` file (+ `.uid`). Refuses non-`.tscn` and the currently-edited scene. |
| `script_delete`         | Delete `.gd` or `.cs` file (+ `.uid`). No open-in-editor guard (see iter-15 Handoff). |
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
  in memory and are lost on editor close. (File-level `scene_create` /
  `scene_delete` / `script_delete` write directly to disk — no
  `editor_save_scene` needed for those.)
- **After `script_write`, call `editor_get_errors`.** Lets you catch syntax
  issues before trusting the file.
- **The Godot editor with this plugin enabled must be running** — the bridge
  has no way to launch Godot for you. If `/mcp` shows the server as
  disconnected, check Project Settings → Plugins → "Godot MCP Toolkit".
- **Idempotency (`status` discriminator, iter 15):** every `create_*` success
  payload carries a `status` field:
  - `"created"` — fresh create.
  - `"returned"` — the thing already existed (idempotent no-op; default path
	for `scene_create_node`, `signal_connect`, and `scene_create` with
	`if_exists: "return"`).
  - `"replaced"` — only from `scene_create` with `if_exists: "replace"`
	(file-level); the response also carries `previous_root_type`.

  Error payloads still carry `code` (`ALREADY_EXISTS` via `scene_create`'s
  opt-in `if_exists: "fail"`; `INVALID_CLASS`, `INVALID_PATH`,
  `PARENT_NOT_FOUND`, etc.). Success payloads do NOT carry `code` — the
  `status` discriminator replaces the legacy `code`-in-success pattern.
  See the server repo's `CLAUDE.md` **Error code reference** for the canonical
  list (keep in sync per watch-item #3).

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

**Dogfood from this repo root.** Post-iter-13c, the F3 frame-skip mitigation
in `mcp_server.gd` makes the Godot 4.4.1 TCPServer race effectively
unreachable under normal use — toolkit-root + `claude` is back to being the
canonical dogfood workflow. Full crash history in the plan repo's
`Plan/Reports/2026-04-15-godot-44-tcpserver-crash-dogfood.md` (Test 3
confirmed the fix holds in this scenario). The sibling
`godot-mcp-dogfood-playground/` project is now reserved for clean-project /
end-user-install verification (mainly used during iter 20 AssetLib prep).

```
# one-time
cd <server-repo>
npm install && npm run build

# every session
# 1) open THIS repo root in Godot 4.4+
# 2) Project Settings -> Plugins -> "Godot MCP Toolkit" -> Active
# 3) from THIS repo root (where .mcp.json lives):
claude
# /mcp should list `godot-mcp-toolkit: connected` with 10+ tools.
```

Note: Godot writes window-layout state into `project.godot` on open. That
usually shows up as a one-line diff — `git checkout project.godot` to discard
if you're not intending to commit layout changes.

## End-user install

See [`DISTRIBUTION.md`](./DISTRIBUTION.md) — covers the AssetLib route, the
manual-zip route, and the server-side `npm install -g` step.

## Pointer

Execution plan (all 26 iterations, cross-repo):
`<plan-repo>/Plan/ExecutionPlan/00-index.md`.
