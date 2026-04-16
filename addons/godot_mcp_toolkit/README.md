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
3. Run `claude`. `/mcp` should list `godot-mcp-toolkit` with the full tool
   catalogue (33 tools default; pass `--lite` in `.mcp.json` args for an
   18-tool core subset in token-sensitive sessions).

(Iter 21 will add a one-click menu item in the editor's MCP dock that writes
`.mcp.json` for you.)

## Iter 15 additions — file-level scene/script ops

- `scene_create` — create a new `.tscn` at a `res://` path. Idempotent via
  the `status` discriminator (`"created"` / `"returned"` / `"replaced"`).
  Accepts optional `if_exists`: `"return"` (default, silent no-op on
  collision), `"fail"` (hard `ALREADY_EXISTS` error), `"replace"` (overwrite
  with a `push_warning` traceable via `editor_get_errors`). Supports native
  engine classes AND custom `class_name` / `[GlobalClass]` types.
- `scene_delete` — remove a `.tscn` (+ its `.uid` companion on 4.4+). Refuses
  non-`.tscn` paths and the currently-edited scene.
- `script_delete` — remove a `.gd` / `.cs` script (+ `.uid` companion).
  Symmetric with `scene_delete` but deliberately has no "currently-open"
  guard (the script editor has no single "current" analog).

### `status` discriminator convention

Every `create_*` success payload now carries a `status` field:

- `"created"` — fresh create.
- `"returned"` — idempotent no-op; the thing already existed (default
  `if_exists: "return"` path on file-level creates `scene_create` /
  `resource_create`, plus every node-level create like `scene_create_node`,
  `signal_connect`, and `folder_create` on a pre-existing directory).
- `"replaced"` — file-level create with `if_exists: "replace"` only.

Error payloads still carry `code` (e.g. `ALREADY_EXISTS` via
`scene_create`'s `if_exists: "fail"` opt-in). Success payloads do NOT carry
`code`.

## Iter 15b additions — resource / folder / shader ops

- `resource_create` — author `.tres` / `.res` at a `res://` path for a
  Resource subclass (engine class or custom `class_name X extends Resource`).
  Idempotent via the same `status` + `if_exists` contract as `scene_create`:
  `"return"` (default), `"fail"` (hard `ALREADY_EXISTS`), `"replace"`
  (overwrite with a `push_warning`). `properties` dict applies engine
  `set()` per key; unknown keys become `warnings: String[]` entries.
  Canonical path for data-driven game content (`EnemyData`, `DialogueNode`,
  themes, materials).
- `resource_save` — update properties on an existing `.tres` / `.res`.
  No `status` field (the absence is the discriminator between
  create and update paths). Same `warnings[]` shape for unknown keys.
- `resource_delete` — remove a `.tres` / `.res` and its `.uid` companion.
  No active-use guard (live `RefCounted` refs survive file deletion;
  detect orphans via `editor_get_errors`).
- `folder_create` — create a `res://` directory (recursive — intermediates
  auto-created). Idempotent: `status: "created"` on fresh, `"returned"` if
  pre-existing. Pairs with `scene_create` / `resource_create`'s
  `PARENT_NOT_FOUND` recovery.
- `folder_delete` — remove a directory. `recursive: false` (default) requires
  an empty directory. Refuses project root, `res://addons`, the toolkit
  plugin directory, and any folder containing the currently-edited scene or
  an open script tab (`PATH_IN_USE`).
- `script_write` / `script_delete` — extension allowlist now includes
  `.gdshader` and `.gdshaderinc` (shader files are text, same handler;
  no separate `shader.*` tool). `script_write` also gained an extension
  guard (previously prefix-only); `.txt` / other non-script extensions now
  reject with `INVALID_PATH`.

### Supported property-value types for `resource_create` / `resource_save`

JSON-native primitives pass through: `bool`, `int`, `float`, `String`, `null`,
`Array`, `Dictionary`. Dict-wrapped engine types coerce via the plugin's
`_coerce_value`:

- `{ "type": "Vector2", "x": 0, "y": 0 }` → `Vector2`
- `{ "type": "Vector3", "x": 0, "y": 0, "z": 0 }` → `Vector3`
- `{ "type": "Color", "r": 0, "g": 0, "b": 0, "a": 1 }` → `Color`

`NodePath` values pass as `String` — Godot's `set()` coerces. Sub-resource
references (`preload("res://...")`) and `Callable` values are NOT supported
here; edit the `.tres` directly via `script_write` on the file if those are
needed.

### Side-effect note — custom Resource classes

`resource_create` instantiates a custom `class_name X extends Resource` via
`script.new()`, which runs `_init()`. If `_init()` has non-trivial side
effects (global state, signal emission, editor-visible mutations), those
will fire every time `resource_create` is called for that class.

## Port

`127.0.0.1:6505` — localhost-only bind. Override by setting `GODOT_MCP_PORT`
on the server-side env.

## Minimum Godot version

Godot 4.4+. See the [repo-root README](../../README.md) for the full stack
overview and dogfood workflow.

## Licence

MIT — see `LICENSE` at the repo root. Upstream architectural references are
credited in `ATTRIBUTIONS.md` at the repo root.
