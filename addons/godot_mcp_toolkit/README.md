# Godot MCP Toolkit

Godot 4.2+ editor plugin that runs a localhost (`127.0.0.1:6550`) WebSocket
server so Claude Code (or any MCP-compatible client) can drive scene, node,
script, and editor operations inside the Godot editor.

## Install

**Via Godot Asset Library** (once the plugin is submitted):
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

Requires Node.js ≥ 22. Source + README:
<https://github.com/NPGameDev/godot-mcp-server>

## Connect Claude Code

**Fastest path (editor menu):** In the Godot editor, go to
**Project → Tools → MCP: Write .mcp.json**. This copies the template
into your project root — restart Claude Code to pick it up.

**Manual fallback:** Copy `addons/godot_mcp_toolkit/.mcp.json.template`
into your project root (same folder as `project.godot`) and rename it to
`.mcp.json`.

Then `cd` to your project root and run `claude`. `/mcp` should list
`godot-mcp-toolkit` with the full tool catalogue — a lean set loads eagerly at
startup and the rest load on demand when Claude Code calls `discover_tools`.

**Cleanup note:** If you delete the `addons/godot_mcp_toolkit/` folder
without disabling the plugin first, `_disable_plugin()` cannot fire.
Manually delete `.mcp.json` from your project root if uninstalling.

## File-level scene/script ops

- `scene_create` — create a new `.tscn` at a `res://` path. Idempotent via
  the `status` discriminator (`"created"` / `"returned"` / `"replaced"`).
  Accepts optional `if_exists`: `"return"` (default, silent no-op on
  collision), `"fail"` (hard `ALREADY_EXISTS` error), `"replace"` (overwrite
  with a `push_warning` traceable via `editor_get_console`). Supports native
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

## Resource / folder / shader ops

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
  detect orphans via `editor_get_console`).
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

### Supported property-value types for `resource_create` / `resource_save` / `node_set_property` / `node_call_method` args

JSON-native primitives pass through: `bool`, `int`, `float`, `String`, `null`,
`Array`, `Dictionary`. Dict-wrapped engine types coerce via the plugin's
`_coerce_value`:

- `{ "type": "Vector2", "x": 0, "y": 0 }` → `Vector2`
- `{ "type": "Vector3", "x": 0, "y": 0, "z": 0 }` → `Vector3`
- `{ "type": "Vector4", "x": 0, "y": 0, "z": 0, "w": 0 }` → `Vector4`
- `{ "type": "Color", "r": 0, "g": 0, "b": 0, "a": 1 }` → `Color`
- `{ "type": "Rect2", "x": 0, "y": 0, "w": 0, "h": 0 }` → `Rect2`
- `{ "type": "Rect2i", "x": 0, "y": 0, "w": 0, "h": 0 }` → `Rect2i`
- `{ "type": "Vector2i", "x": 0, "y": 0 }` → `Vector2i` (TileMap coords)
- `{ "type": "Vector3i", "x": 0, "y": 0, "z": 0 }` → `Vector3i`
- `{ "type": "Transform2D", "origin": {x,y}, "x_axis": {x,y}, "y_axis": {x,y} }` → `Transform2D` (animation keyframes)
- `{ "type": "Transform3D", "basis": { "x": {x,y,z}, "y": {x,y,z}, "z": {x,y,z} }, "origin": {x,y,z} }` → `Transform3D`
- `{ "type": "NodePath", "path": "CanvasLayer/HUD" }` → `NodePath`
- `{ "type": "Resource", "path": "res://art/player.png" }` → loaded via
  `ResourceLoader.load` (any `Resource` subclass: `Texture2D`, `PackedScene`,
  `Material`, custom `class_name X extends Resource`, etc.). Missing paths
  surface as hard `LOAD_FAILED` on `node_set_property` / `node_call_method`
  (a null texture renders as a pink checkerboard at runtime — caller deserves
  an error); as a `warnings[]` entry on `resource_create` / `resource_save`
  (authoring a `.tres` with a placeholder path is a valid probing workflow).

Arrays recurse element-wise, so `node_call_method` args can mix primitives
and typed dicts: `[{type:"Vector2",x:32,y:32}, 0.5, "hello"]`.

Not yet coerced (add as needs arise): `Basis`,
`Quaternion`, `Plane`, `AABB`, `Projection`, the `Packed*Array` family,
`Callable`, `Signal`. Edit the `.tres` directly via `script_write` on the
file if you need these.

## Playtest + composition + method invocation

- `game_start` — drive the editor's play button via
  `EditorInterface.play_*_scene()`. `target` accepts `"main"` (uses
  ProjectSettings `application/run/main_scene`), `"current"` (default —
  currently-edited scene), or any `res://path.tscn`. `wait_for_runtime: true`
  (default) polls `127.0.0.1:6570` for up to 5s so the agent can chain
  Mode-B runtime RPCs without a separate probe. `ALREADY_PLAYING` if a
  game is already running (stop-then-start is explicit so the agent sees
  the transition).
- `game_stop` — `EditorInterface.stop_playing_scene()`. Idempotent in the
  stop direction: `was_running: false` when nothing was live (no error —
  the update-shape "make it so" rationale parallels `resource_save`).
- `scene_instantiate` — drop a `PackedScene` under a parent in the edited
  scene. UndoRedo-wrapped (crash guard per the `delete_node` pattern).
  Recursive owner-set (every descendant, not just root) — without it
  `editor_save_scene` silently drops the instantiated subtree. Silent
  return on name collision (`status: "returned"`); fresh creates emit
  `status: "created"`. Optional `as_name` renames the instance; optional
  `transform` dict applies `position` / `rotation` / `scale` / `size`
  (silent no-op on unknown keys — subtype-agnostic across
  `Node2D` / `Node3D` / `Control`).
- `node_call_method` — invoke a node's method with arguments.
  `has_method`-gated (`INVALID_METHOD` on miss) so callers can't reach
  arbitrary symbols. Arguments pass through `_coerce_value` so Resource
  refs + typed dicts work in `args`. Return value serialises via the
  same path as `node_get_property` (primitives / Arrays / Dicts
  round-trip; `Node` refs stringify to their path; `Resource` refs emit
  `{type:"Resource",path,class}`). Mode A only — runtime-live node
  invocation is deferred. Annotated `destructiveHint: true`
  — agents see the risk signal via MCP annotations.

### Side-effect note — custom Resource classes

`resource_create` instantiates a custom `class_name X extends Resource` via
`script.new()`, which runs `_init()`. If `_init()` has non-trivial side
effects (global state, signal emission, editor-visible mutations), those
will fire every time `resource_create` is called for that class.

## Content-authoring extensions

Five new domains, ~10 tools. All honour the `status` discriminator + the
expanded `_coerce_value` set above (5 new type tags: `Vector2i`, `Vector3i`,
`Rect2i`, `Transform2D`, `Transform3D`).

- `project_set_setting` — write any `ProjectSettings` key + persist via
  `ProjectSettings.save`. Refuses `mcp_toolkit/*` (toolkit's internal settings) and
  `editor/*` (editor-session state, not project config) — defence-in-depth
  against an agent disabling its own constraints. UPDATE shape (no
  `status`); returns `was_set_before` + `previous_value` for observability.
  Pairs with `project_get_settings`. Annotated `destructiveHint: true` —
  high blast-radius (main scene, autoloads, physics tick).
- `input_map_add_action` / `input_map_action_add_event` /
  `input_map_action_remove_event` / `input_map_remove_action` — write path
  for `InputMap`. Persists to `ProjectSettings.input/<action>` via
  `ProjectSettings.save` (fail-open: in-memory change is observable for
  this session; persistence-failure surfaces as `push_warning`).
  `input_map_remove_action` refuses Godot's built-in `ui_*` actions
  (`ui_accept`, `ui_cancel`, `ui_focus_next`, etc. — full list pinned in
  `mcp_server.gd`'s `_BUILTIN_UI_ACTIONS` constant; cross-check on Godot
  upgrade). Event-dict schema:
  - `{ type: "key", keycode: "SPACE"|"A"|int, shift, ctrl, alt, meta }` —
	`keycode` accepts symbolic name via `OS.find_keycode_from_string` or raw int.
  - `{ type: "mouse_button", button_index: int, pressed: bool }`
  - `{ type: "joypad_button", button_index: int, device: int }` —
	`device: -1` matches any.
  - `{ type: "joypad_motion", axis: int, axis_value: float, device: int }`
- `animation_add_key` / `animation_remove_key` / `animation_get_keys` —
  `AnimationPlayer` track + keyframe authoring. `TYPE_VALUE` tracks only
  (`bezier` / `transform` / `method` / `audio` deferred). Auto-creates the value track if `track_path` (e.g.
  `Sprite2D:position`) doesn't yet exist on the named animation. Bare
  NodePaths (no `:` property suffix) reject with `INVALID_PARAMS`.
  UndoRedo-wrapped both directions; silent-return on exact-time duplicate.
- `tilemap_set_cells` — batch paint `TileMap` (4.2 / pre-deprecated layer
  API) or `TileMapLayer` (4.3+). Single UndoRedo action across the whole
  batch. Cell descriptor:
  `{ x, y, source_id, atlas_x, atlas_y, alternative_tile? }` —
  `source_id: -1` clears that cell. Returns
  `{ cells_written, cells_unchanged, total }` so the agent can tell what
  the batch actually changed (idempotent overwrites count separately).
  Per-cell `set_cell` calls would saturate the WebSocket on even modest
  grids (a 32×32 level = 1024 round-trips); batching collapses to one.
- `editor_screenshot_node` — focus + capture a single node in the editor
  viewport. Uses `EditorInterface.edit_node` to frame the node, then
  `await RenderingServer.frame_post_draw` for a clean repaint, then
  captures from `get_editor_viewport_2d()` or `get_editor_viewport_3d(0)`
  based on the node's class. Atomic prior-selection restore (best-effort:
  selection is restored, viewport camera pan is not). Inline base64 PNG
  same as `editor_screenshot`. Closes the visual-verification gap when
  the full editor viewport is too wide.

### InputMap persistence note

`InputMap.add_action` / `action_add_event` mutate **in-memory** Godot
state. The persistence step writes `ProjectSettings.input/<action>` so
the change survives editor restart. Persistence is **fail-open**:
`ProjectSettings.save` returning non-OK pushes a warning but the tool
returns success — the in-memory InputMap is observable for the current
session's runtime. If a `game_start` runs immediately after, the
runtime sees the new bindings (Godot loads `InputMap` from
`ProjectSettings` at game boot from the in-memory entries).

## Asset discovery + editor console

- `asset_list` — enumerate `res://` assets via Godot's `EditorFileSystem`
  index (no full-load). Filters: `path_prefix`, `name_glob` (case-insensitive
  `matchn`), `class_filter` (ancestry-aware via `ClassDB.is_parent_class`),
  `extension_filter`. Returns `[{ path, class, modified_unix }]`. Cap
  `limit` at 2000 (default 500). `FILESYSTEM_NOT_READY` if mid-scan.
- `asset_get_dependencies` — forward dependencies of a `res://` resource or
  scene. Uses `ResourceLoader.get_dependencies` (O(1) cached after scan).
  `include_transitive: true` does a breadth-first walk with cycle-safe
  visited set. Returns `[{ path, raw_path, class }]`.
- `editor_get_console` — tail the editor's Output panel via `user://logs/`.
  Params: `limit` (default 200, cap 1000), `level_filter` (`info` /
  `warning` / `error`), `since_id` for incremental polling. Log-file
  selection heuristic prefers `godot.log` post-plugin-boot; fallback to
  most-recent `.log`. Multi-line error blocks (stack traces starting with
  whitespace or `"   at:"`) are folded into the preceding entry.
  `LOG_UNAVAILABLE` if no readable log file exists.
- `editor_get_errors` — **removed** (no longer registered). There is no
  `editor.get_errors` command; the error path is `editor_get_console` with
  `level_filter=["error"]`, which provides the same data with richer output
  (autoload + empty-buffer hints).

### Console-reader notes

- **`user://logs/` read exception.** This is a narrow read-only deviation from
  the `res://`-only path rule: the console reader reads an
  **internally-constructed** `user://logs/` path (never caller-supplied), so it
  sits outside FileGuard's path validation rather than being allowlisted through
  it.
- **Playtest-rotation ambiguity.** When a Mode-B playtest starts, Godot
  rotates the editor's log; `editor.get_console` may surface game output
  instead. Prefer `debugger.get_log` during playtest.
- **No per-line timestamps** in default Godot log format. `timestamp_unix` is
  `null`; agents that need per-entry timing should use `--verbose`.
- **`debug/file_logging/enable_file_logging=false`** → `LOG_UNAVAILABLE` with
  the settings key in the message.

## Binary asset import + scan-idle gating

- `asset_import` — import a binary file (image, audio, font, 3D model, etc.)
  into `res://` via one of two modes: `source_path` (absolute filesystem copy)
  or `base64_data` (inline base64-encoded bytes). Extension allowlist covers
  Godot's built-in importer types (`png`, `wav`, `glb`, `ttf`, `ogg`, …);
  text-based formats with dedicated tools (`.gd`, `.tscn`, `.tres`) are
  rejected with a message pointing to the correct tool. Idempotent via
  `if_exists: "return"` (default) / `"fail"` / `"replace"`. Triggers
  `EditorFileSystem.scan()` after write; `wait_for_scan_ms` (default 5000,
  cap 30000) polls until the import pipeline finishes. Size limits: 50 MB
  filesystem, 5 MB decoded base64.
- `editor_wait_for_idle` — poll `EditorFileSystem.is_scanning()` until idle
  or `timeout_ms` (default 10000, cap 30000). Returns immediately if not
  scanning. Use after `asset.import`, `editor.refresh`, or any
  operation that triggers a filesystem rescan. Replaces the agent-side blind
  `setTimeout` retry pattern — one deterministic wait instead of N guesses.

### Source-path note

`asset.import` is the first tool to read outside `res://` / `user://`.
The `source_path` parameter accepts an **absolute OS filesystem path**
(e.g. `C:\Users\me\sprites\hero.png` on Windows, `/home/me/sprites/hero.png`
on Linux). `FileGuard` provides a source-path allowlist;
the extension allowlist + size cap provide defence in depth.

## Concurrent human + MCP editing

You can keep working in the editor while MCP tool calls run. Concurrent editing
is validated for: creating nodes during scene-tree edits, undo interleaving
(Ctrl+Z undoes the most recent action — MCP or manual — first), acting on a node
while its Inspector is open, and mid-drag reparenting — no crashes.

**Caveat — unsaved script buffers.** If you have a script open in the built-in
editor with **unsaved changes** and an MCP tool writes the same file, the
editor's in-memory buffer wins on your next save and can overwrite the tool's
write. For same-file edits, save or close the script first (or take turns).

## Port

`127.0.0.1:6550` — localhost-only bind, auto-scanned from the `6550–6560` band.
To pin an exact editor port, set **`GODOT_MCP_EDITOR_PORT`** (the runtime/Mode-B
server uses **`GODOT_MCP_RUNTIME_PORT`**); to relocate the scan band instead, set
`GODOT_MCP_EDITOR_PORT_MIN` / `_MAX` (and the matching `RUNTIME` pair). A pin must
be set on **both** the editor process and the MCP server env so the two agree —
see [docs/advanced_configuration.md](docs/advanced_configuration.md) and
[docs/multi-instance.md](docs/multi-instance.md).

## Advanced configuration

Optional fine-tuning knobs (concurrency timeouts, buffer limits) live under
`mcp_toolkit/` in Project Settings — most users never need them. See
[docs/advanced_configuration.md](docs/advanced_configuration.md).

## Minimum Godot version

Godot 4.2+. See the [repo-root README](../../README.md) for the full stack
overview and dogfood workflow.

## Licence

MIT — see `LICENSE` at the repo root. Upstream architectural references are
credited in `ATTRIBUTIONS.md` at the repo root.
