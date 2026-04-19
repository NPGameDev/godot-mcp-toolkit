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

## Core tool catalogue (31 lite-core tools — iter 08 + iter 15 + iter 15b + iter 15c + iter 15d + iter 15e + iter 15f + iter 15g + iter 15h + iter 15i)

Additional Tier 1–3 tools from iter 09–12 (`editor_reload_scripts`,
`scene_open`, `project_get_settings`, `signal_*`, `resource_load`,
`scene_diff`, `node_get_property_list`, and the Mode B `runtime_*` family)
plus iter 15c's playtest/composition additions, iter 15d's
content-authoring extensions, iter 15e's asset-discovery +
console-reading, and iter 15f's binary-asset import + scan-idle gating
bring the full catalogue to 49 tools by default (60 with all feature
gates enabled — see **Feature gates** below). Pass `--lite` in
`.mcp.json` args for a 14-tool token-sensitive subset.

| Tool                    | One-liner                                                                        |
|-------------------------|----------------------------------------------------------------------------------|
| `scene_get_tree`        | Return the edited scene as nested JSON `{ name, class, path, children }`.        |
| `scene_create_node`     | Create node of `class_name` (engine + user-defined `class_name` classes) under `parent`. Idempotent. |
| `scene_delete_node`     | Delete node at `path`. UndoRedo-based; refuses to delete the edited-scene root.  |
| `scene_create`          | Create `.tscn` file at `path` with root `root_type`. Idempotent; `if_exists: return\|fail\|replace`. |
| `scene_delete`          | Delete `.tscn` file (+ `.uid`). Refuses non-`.tscn` and the currently-edited scene. |
| `scene_close`           | Close an open scene tab by path. Refuses the last remaining tab (EDITED_SCENE). NOT_FOUND if not open. Lite. |
| `script_delete`         | Delete `.gd`/`.cs`/`.gdshader`/`.gdshaderinc` (+ `.uid`). No open-in-editor guard. |
| `resource_create`       | Create `.tres`/`.res` at `path` for `resource_class`. Idempotent; `if_exists: return\|fail\|replace`; `properties` + `warnings[]`. |
| `resource_save`         | Update `.tres`/`.res` properties at `path`. No `status` (absence = update). `warnings[]` for unknown keys. |
| `resource_delete`       | Delete `.tres`/`.res` (+ `.uid`). No active-use guard (refs persist via RefCounted). |
| `folder_create`         | Create `res://` directory (recursive). Idempotent: `status: "created"`/`"returned"`. |
| `folder_delete`         | Delete directory. `recursive:false` default. Refuses root/addons/plugin/open-file parents. |
| `node_get_property`     | Read a property. Engine types (Vector2, Color, …) come back dict-wrapped.        |
| `node_set_property`     | Write a property. Pass engine types as `{ type: "Vector2", x: 0, y: 0 }`.        |
| `node_set_script`       | Attach a script (.gd/.cs) to a node. Returns @export properties. Empty `script` detaches. Lite. |
| `script_read`           | Read a GDScript / text file (`res://` only).                                     |
| `script_write`          | Write `.gd`/`.cs`/`.gdshader`/`.gdshaderinc` at `path` (`res://` only). Overwrites. |
| `editor_get_errors`     | Editor-time error tail (delegates to `editor.get_console` with `level='error'`). Iter 15e: stub replaced with real console reader. |
| `editor_save_scene`     | Save the current edited scene. Optional `path` → save-as.                        |
| `editor_screenshot`     | Capture the editor viewport; returns inline image content (+ optional `save_path`). |
| `game_start`            | Drive editor play button. `target: "main"\|"current"\|res://*.tscn`. `ALREADY_PLAYING` if one is live. Lite. |
| `game_stop`             | `EditorInterface.stop_playing_scene()`. Idempotent; response carries `was_running: bool`. Full only.          |
| `scene_instantiate`     | Drop `PackedScene` under a parent. UndoRedo-wrapped + recursive owner-set. Idempotent (`status: "returned"` on name collision). Lite. |
| `node_call_method`      | Invoke `node.method(args...)` with `_coerce_value`-coerced args. `has_method`-gated. Mode A only in 15c. Full only. |
| `project_set_setting`   | Write a `ProjectSettings` key + `ProjectSettings.save`. Refuses `mcp/unsafe/*` and `editor/*`. UPDATE (no `status`); returns `previous_value`. Lite. |
| `input_map_add_action`  | Register an `InputMap` action with deadzone. Idempotent — `status: "returned"` reports the EXISTING deadzone (not the requested one). Lite. |
| `input_map_action_add_event` | Bind a `key`/`mouse_button`/`joypad_button`/`joypad_motion` event-dict to an action. Silent-return on equivalent-event duplicate. Lite. |
| `input_map_action_remove_event` | Unbind a matching event from an action. `NOT_FOUND` if no equivalent event is bound. Full only. |
| `input_map_remove_action` | Erase an `InputMap` action. Refuses built-in `ui_*` actions (would break editor/engine nav). Full only. |
| `animation_add_key`     | Insert a `TYPE_VALUE` keyframe on an `AnimationPlayer` track. Auto-creates the track if missing. UndoRedo-wrapped; silent-return on exact-time duplicate. Lite. |
| `animation_remove_key`  | Remove a keyframe at exact `time`. UndoRedo-wrapped (captured value flows through undo). Full only. |
| `animation_get_keys`    | Read-only listing: `{ time, value, transition }` per key + `track_type` enum string. No auto-track-create. Lite. |
| `tilemap_set_cells`     | Batch-paint `TileMap` or `TileMapLayer`. Single UndoRedo action. Returns `cells_written` + `cells_unchanged` + `total`. `source_id: -1` clears. Lite. |
| `editor_screenshot_node` | Focus + capture a specific node in the editor viewport (`await RenderingServer.frame_post_draw`). Atomic prior-selection restore. Inline base64 PNG. Full only. |
| `asset_list`            | Enumerate `res://` assets with `path_prefix`, `name_glob`, `class_filter` (ancestry-aware), `extension_filter`. Cap 2000. Lite. |
| `asset_get_dependencies` | Forward deps of a `res://` resource/scene. `include_transitive` for BFS walk. Full only. |
| `editor_get_console`    | Tail editor Output panel (`user://logs/`). `level_filter`, `since_id` for incremental. Lite. |
| `asset_import`          | Import binary asset (image/audio/font/3D) into `res://` via `source_path` (filesystem copy) or `base64_data`. Extension allowlist; `if_exists: return\|fail\|replace`. Triggers scan + optional wait. Lite. |
| `editor_wait_for_idle`  | Poll `EditorFileSystem.is_scanning()` until idle or `timeout_ms` (default 10s, cap 30s). Use after `asset.import`, `editor.reload_scripts`, or file mutations. Full only. |
| `file_delete`           | Delete any `res://` file and its `.import`/`.uid` companions. Universal fallback for assets not covered by scene/script/resource.delete. Full only. |
| `save_read`             | Read whitelisted `user://` file (default 64 KB cap; max 256 KB). Returns UTF-8 in `<untrusted>` envelope or base64 if non-UTF-8. Gated by `read_user_scope`. Full only. |
| `save_write`            | Write to whitelisted `user://` file (creates parent dirs). Not idempotent; no `if_exists`. Gated by `read_user_scope`. Full only. |
| `save_delete`           | Delete whitelisted `user://` file. `NOT_FOUND` if missing. Delete paths configured separately in whitelist. Gated by `read_user_scope`. Full only. |
| `save_list`             | List files + subdirs in a whitelisted `user://` directory (path must end `/`). Names only. Gated by `read_user_scope`. Full only. |

## Security (iter 18)

- **Session-token auth.** On plugin start the editor generates a 32-byte hex
  token and writes it to `user://mcp_token` (platform-resolved — see table
  below). The bridge reads this file on every connect/reconnect and sends
  `{"auth":"<token>"}` as the first WebSocket message. Peers that don't
  authenticate within 2 s are closed with WS code 1008.

  | Platform | Token path                                                       |
  |----------|------------------------------------------------------------------|
  | Windows  | `%APPDATA%\Godot\app_userdata\<project>\mcp_token`               |
  | macOS    | `~/Library/Application Support/Godot/app_userdata/<project>/mcp_token` |
  | Linux    | `~/.local/share/godot/app_userdata/<project>/mcp_token`          |

  Override with env `GODOT_MCP_TOKEN_PATH` if needed (e.g. multi-project
  setups in iter 23).

  **Do not check this file in or share it.** The token rotates on every plugin
  start; stale tokens are harmless but useless.

- **FileGuard (`file_guard.gd`).** Every command that accepts a file path
  routes through `FileGuard.resolve_safe(path)`. Rejects `..` segments,
  absolute OS paths, and non-`res://` prefixes. `editor.screenshot` also
  allows `user://screenshots/`. Paths that escape the project boundary after
  canonicalisation are rejected.

- **Untrusted envelopes.** Read-path outputs (script content, scene tree,
  project settings, error logs, resource properties, animation keys) are
  wrapped in `<untrusted-{nonce} kind="…" source="…">` envelopes
  (per-call random 8-hex-char nonce) to mark user-authored content for
  the LLM. Envelope-tag variants in the body are scrubbed before wrapping
  to prevent tag-breakout injection. Write paths are never wrapped. The
  envelope is a defense-in-depth hint, not a security boundary — the real
  boundaries are FileGuard, FeatureGate, token auth, and the audit log.

## Feature gates (iter 19)

Seven features are gated behind explicit opt-in. By default all gates are
**off** — gated tools are absent from the MCP catalogue entirely and
plugin-side handlers return `FEATURE_DISABLED` as defence-in-depth.

| Feature               | Gate type | Env var                                  | ProjectSettings key                        | Risk |
|-----------------------|-----------|------------------------------------------|--------------------------------------------|------|
| `game_eval`           | **dual**  | `GODOT_MCP_ALLOW_GAME_EVAL`             | `mcp/unsafe/allow_game_eval`               | Arbitrary GDScript via Expression |
| `os_execute`          | **dual**  | `GODOT_MCP_ALLOW_OS_EXECUTE`            | `mcp/unsafe/allow_os_execute`              | Host-OS shell execution |
| `project_set_setting` | **dual**  | `GODOT_MCP_ALLOW_PROJECT_SET_SETTING`   | `mcp/unsafe/allow_project_set_setting`     | Write arbitrary ProjectSettings keys |
| `outbound_http`       | **dual**  | `GODOT_MCP_ALLOW_OUTBOUND_HTTP`         | `mcp/unsafe/allow_outbound_http`           | Outbound HTTP requests |
| `node_call_method`    | single    | `GODOT_MCP_ALLOW_NODE_CALL_METHOD`      | `mcp/unsafe/allow_node_call_method`        | Method invocation on edited-scene nodes |
| `input_map_write`     | single    | `GODOT_MCP_ALLOW_INPUT_MAP_WRITE`       | `mcp/unsafe/allow_input_map_write`         | Modify persistent InputMap actions |
| `read_user_scope`     | **dual**  | `GODOT_MCP_ALLOW_USER_SCOPE`            | `mcp/unsafe/allow_user_scope`              | Read/write whitelisted user:// paths |

- **Dual gate** — BOTH env var (`=1`) AND ProjectSettings must be true.
- **Single gate** — EITHER env var OR ProjectSettings suffices.
- **Explicit deny** — Setting `mcp/unsafe/deny_<feature>` to `true` in
  ProjectSettings always wins, regardless of other flags.

### How to enable

Set the env var in `.mcp.json` `env` block:
```json
{ "env": { "GODOT_MCP_ALLOW_NODE_CALL_METHOD": "1" } }
```

For dual-gate features, also flip the ProjectSettings toggle:
Project Settings → Advanced Settings → MCP → Unsafe → `allow_<feature>`.

### user:// whitelist (iter 19c)

The `save.*` tools access `user://` paths filtered by a plugin-author-configured
whitelist at `addons/godot_mcp_toolkit/user_scope_whitelist.json`. The whitelist
is NOT agent-configured — the plugin author edits it before shipping; end users
who enable the gate trust the author's whitelist.

```json
{
  "$schema_version": 1,
  "read":   ["saves/", "logs/"],
  "write":  ["saves/"],
  "delete": ["saves/"]
}
```

- Entries are relative to `user://`. Trailing `/` = prefix match; no trailing
  `/` = exact match. No wildcards, no `..`.
- Separate `read`/`write`/`delete` keys let the author grant "read logs but not
  write/delete them" granularity.
- Symlink escape guard: paths that resolve outside `OS.get_user_data_dir()` are
  rejected regardless of whitelist match.

To enable the `save.*` tools:
1. Set `GODOT_MCP_ALLOW_USER_SCOPE=1` in `.mcp.json` env block.
2. Enable `mcp/unsafe/allow_user_scope` in Project Settings → Advanced.
3. Ensure `user_scope_whitelist.json` exists and is valid JSON.

### Breaking changes vs pre-iter-19

- `node_call_method` (was always-on since iter 15c) — now requires
  `node_call_method` gate (single).
- `project_set_setting` (was always-on since iter 15d) — now requires
  `project_set_setting` gate (dual).
- `input_map_add_action`, `input_map_action_add_event`,
  `input_map_action_remove_event`, `input_map_remove_action` (always-on
  since iter 15d) — now require `input_map_write` gate (single).

### Error shape

When a gated tool is called while disabled, the plugin returns:
```json
{
  "success": false,
  "code": "FEATURE_DISABLED",
  "error": "Feature '<name>' is disabled …",
  "risk": "<risk description>",
  "how_to_enable": "Set env GODOT_MCP_ALLOW_… = 1 [and …]"
}
```

## Conventions when driving these tools

- **Paths always use `res://`.** No absolute filesystem paths. `FileGuard`
  rejects anything outside `res://` (plus `user://screenshots/` for
  screenshots only).
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
- **Idempotency (`status` discriminator, iter 15 + iter 15b):** every
  `create_*` success payload carries a `status` field:
  - `"created"` — fresh create.
  - `"returned"` — the thing already existed (idempotent no-op; default path
	for `scene_create_node`, `signal_connect`, `folder_create`, and file-level
	`scene_create` / `resource_create` with `if_exists: "return"`).
  - `"replaced"` — only from file-level `scene_create` / `resource_create`
	with `if_exists: "replace"`; the response also carries
	`previous_root_type` / `previous_class` respectively.

  `resource_save` is the odd one out: it's an update (not a create), so it
  carries NO `status` field. The absence is itself the discriminator.

  Error payloads still carry `code` (`ALREADY_EXISTS` via `scene_create` /
  `resource_create`'s opt-in `if_exists: "fail"`; `INVALID_CLASS`,
  `INVALID_PATH`, `PARENT_NOT_FOUND`, `NOT_A_RESOURCE`, `DIR_NOT_EMPTY`,
  `FOLDER_PROTECTED`, `PATH_IN_USE`, `CREATE_DIR_FAILED`, etc.). Success
  payloads do NOT carry `code` — the `status` discriminator replaces the
  legacy `code`-in-success pattern. See the server repo's `CLAUDE.md`
  **Error code reference** for the canonical list (keep in sync per
  watch-item #3).

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
