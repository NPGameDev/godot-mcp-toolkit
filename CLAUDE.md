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

Runs a localhost WebSocket server inside the Godot editor (dynamic port
`127.0.0.1:6505–6515`) and exposes scene, node, script, and editor operations
to any MCP client (e.g. Claude Code via the companion
`@npgamedev/godot-mcp-server` npm package). A runtime server (`127.0.0.1:9090–9105`)
runs in debug builds for live-game introspection (Mode B).

## Tool catalogue (57 tools — iter 22 profile system + iter 26 classdb)

Iter 22 replaces the coarse lite/full flag with profiles + lazy-load groups.
Set `GODOT_MCP_PROFILE` in `.mcp.json` env block:

| Profile      | Visible tools |
|--------------|--------------|
| **standard** (default) | 31 core + `enable_tool_group` meta-tool + 3 locked stubs |
| **minimal** | 10 read-only (code-review mode) |
| **full**     | All 57 tools at startup |
| **custom**   | `GODOT_MCP_CUSTOM_TOOLS` comma-list |

`--lite` → `minimal` with deprecation warning. `GODOT_MCP_READ_ONLY=1`
strips mutating tools from any profile.

### Core tools (always-on in standard profile)

| Tool                    | One-liner                                                                        |
|-------------------------|----------------------------------------------------------------------------------|
| `scene_get_tree`        | Return the edited scene as nested JSON. `depth` (default 2), `include_properties` (default false). |
| `scene_create_node`     | Create node under `parent`. Idempotent. |
| `scene_delete_node`     | Delete node at `path`. UndoRedo-based; refuses the root.  |
| `scene_create`          | Create `.tscn` file. Idempotent; `if_exists: return\|fail\|replace`. |
| `scene_instantiate`     | Drop `PackedScene` under a parent. UndoRedo-wrapped. Idempotent. |
| `scene_open`            | Open a scene in the editor. |
| `scene_diff`            | Compare current edited scene tree against on-disk version. |
| `node_get_property`     | Read a property. Engine types dict-wrapped. |
| `node_set_property`     | Write a property. Engine types as `{ type, ... }`. |
| `node_get_property_list` | List properties. `mask`: "common" (default, curated), "all", or "groups". |
| `node_set_script`       | Attach/detach script. Returns `@export` properties. |
| `script_read`           | Read a GDScript / text file (`res://` only). |
| `script_write`          | Write `.gd`/`.cs`/`.gdshader`/`.gdshaderinc`. Overwrites. |
| `script_read_range`     | Read lines N–M of a script file. |
| `script_delete`         | Delete `.gd`/`.cs`/`.gdshader`/`.gdshaderinc` (+ `.uid`). |
| `editor_get_errors`     | Editor-time error tail. Summary-first response. |
| `editor_save_scene`     | Save the current edited scene. Optional `path` → save-as. |
| `editor_screenshot`     | Capture the editor viewport; inline image content. |
| `editor_screenshot_node` | Focus + capture a specific node. Inline base64 PNG. |
| `editor_reload_scripts` | Force GDScript re-parse. |
| `editor_get_console`    | Tail editor Output panel. `level_filter`, `since_id`. |
| `editor_wait_for_idle`  | Poll until `EditorFileSystem` idle or timeout. |
| `project_get_settings`  | Read ProjectSettings. |
| `game_start`            | Drive editor play button. `target: "main"\|"current"\|res://*.tscn`. |
| `game_stop`             | Stop the running scene. Idempotent. |
| `resource_load`         | Load a `.tres`/`.res` and return its properties. |
| `resource_write`        | Upsert `.tres`/`.res`. Creates if missing (requires `type`), updates otherwise. |
| `folder_create`         | Create `res://` directory. Idempotent. |
| `folder_delete`         | Delete directory. Refuses protected paths. |
| `asset_list`            | Enumerate `res://` assets with filters. |
| `tilemap_set_cells`     | Batch-paint TileMap. Single UndoRedo action. |
| `classdb_get_info`      | Inspect any Godot class: properties, methods, signals, constants, inheritance. Engine + user `class_name`. |

### Lazy-load group tools (via `enable_tool_group`)

| Group                 | Tools |
|-----------------------|-------|
| `runtime`             | `runtime_screenshot`, `runtime_get_node_state`, `debugger_get_log`, `input_simulate`, `animation_player_control` |
| `signals`             | `signal_list`, `signal_manage` (connect/disconnect), `signal_emit` |
| `animation_authoring` | `animation_keyframe` (add/remove), `animation_get_keys` |
| `input_map` (gated)   | `input_map_action` (add/remove), `input_map_event` (bind/unbind) |
| `asset_management`    | `asset_get_dependencies`, `asset_import`, `resource_delete`, `file_delete`, `scene_delete`, `scene_close` |
| `user_data` (gated)   | `save_read`, `save_write`, `save_delete`, `save_list` |

### Gated tools (locked stubs when disabled)

| Tool                  | Gate env var |
|-----------------------|-------------|
| `game_eval`           | `GODOT_MCP_ALLOW_GAME_EVAL` |
| `node_call_method`    | `GODOT_MCP_ALLOW_NODE_CALL_METHOD` |
| `project_set_setting` | `GODOT_MCP_ALLOW_PROJECT_SET_SETTING` |

## Multi-project support (iter 23)

Multiple Godot editors can run the plugin simultaneously. Each editor
dynamically allocates a port from the 6505–6515 range (editor) or 9090–9105
(runtime) and registers itself in a system-wide registry file:

| Platform | Registry path |
|----------|---------------|
| Windows  | `%APPDATA%\godot-mcp-toolkit\projects.json` |
| macOS    | `~/Library/Application Support/godot-mcp-toolkit/projects.json` |
| Linux    | `~/.local/share/godot-mcp-toolkit/projects.json` |

The TypeScript bridge discovers which port belongs to which project by matching
`process.cwd()` (or `GODOT_MCP_PROJECT_PATH` env) against the registry.

**Single-project users need no configuration changes.** Port 6505 is tried
first and will be assigned unless another editor already holds it.

**Decoupled CWD** — if Claude Code's CWD differs from the Godot project root,
set `GODOT_MCP_PROJECT_PATH` in `.mcp.json`:
```json
{ "env": { "GODOT_MCP_PROJECT_PATH": "/absolute/path/to/godot/project" } }
```

**Direct port override** — `GODOT_MCP_PORT` in `.mcp.json` still works and
bypasses registry discovery entirely (backwards compat).

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

## Editor UI (iter 21)

- **MCP dock** — bottom-panel tab ("MCP"). Signal-driven server status (no
  polling), feature-gate toggles with .mcp.json sync indicators, polled audit
  log tail (visibility-gated, 500ms Timer). Action buttons: Regenerate Token,
  Open Full Log, Clear View.
- **Menu items** — five entries under Project → Tools: Regenerate Token, Show
  Audit Log, Open Project Settings, Write .mcp.json, Power User Mode. All also
  registered in the Command Palette (Ctrl+Shift+P → "MCP").
- **Power User Mode** — sets `mcp/unsafe/allow_all = true` in ProjectSettings
  (satisfies the PS side of every gate at once). Also writes all feature env
  vars into `.mcp.json`. Explicit `deny_<feature>` still overrides `allow_all`.
  Accessible from the dock, the Tools menu, the Command Palette, or the
  first-run onboarding dialog.
- **.mcp.json sync** — when toggling a dual-gated feature in the dock, the
  plugin offers to add/remove the corresponding env var in `.mcp.json`.
  Out-of-sync states show a warning icon in the dock's feature row.
- **Plugin disable cleanup** — disabling the plugin via Project Settings →
  Plugins prompts to delete the orphaned `.mcp.json` at project root.
- **Export stripping** — `EditorExportPlugin` auto-strips all
  `addons/godot_mcp_toolkit/` files from exported PCKs (iter 20 `export_strip.gd`).
- **EditorSettings** (per-user, not committed) — `mcp/personal/dock_default_visible`,
  `mcp/personal/audit_log_tail_lines`.

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

### Breaking changes vs pre-iter-22

**Tool merges (iter 22):**
- `signal_connect` + `signal_disconnect` → `signal_manage` (action: "connect"|"disconnect")
- `resource_create` + `resource_save` → `resource_write` (upsert — `type` required for new files)
- `input_map_add_action` + `input_map_remove_action` → `input_map_action` (action: "add"|"remove", `action_name` instead of `action`)
- `input_map_action_add_event` + `input_map_action_remove_event` → `input_map_event` (action: "bind"|"unbind", `action_name` instead of `action`)
- `animation_add_key` + `animation_remove_key` → `animation_keyframe` (action: "add"|"remove")

**Profile system (iter 22):**
- `--lite` deprecated → `GODOT_MCP_PROFILE=minimal`
- Default profile changed from "full" to "standard" (31 core tools + groups on demand)

**Gate changes (iter 19):**
- `node_call_method` — now requires `node_call_method` gate.
- `project_set_setting` — now requires `project_set_setting` gate (dual).
- `input_map_action`, `input_map_event` — now require `input_map_write` gate.

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
- **Idempotency (`status` discriminator):** every `create_*` success
  payload carries a `status` field:
  - `"created"` — fresh create.
  - `"returned"` — the thing already existed (idempotent no-op; default path
	for `scene_create_node`, `signal_manage` connect, `folder_create`, and
	file-level `scene_create` / `resource_write` on new file).
  - `"replaced"` — file-level `scene_create` with `if_exists: "replace"`.

  `resource_write` on an existing file is an update (upsert) — no `status`
  field. The absence is itself the discriminator.

  Error payloads still carry `code` (`ALREADY_EXISTS` via `scene_create` /
  `resource_create`'s opt-in `if_exists: "fail"`; `INVALID_CLASS`,
  `INVALID_PATH`, `PARENT_NOT_FOUND`, `NOT_A_RESOURCE`, `DIR_NOT_EMPTY`,
  `FOLDER_PROTECTED`, `PATH_IN_USE`, `CREATE_DIR_FAILED`, etc.). Success
  payloads do NOT carry `code` — the `status` discriminator replaces the
  legacy `code`-in-success pattern. See the server repo's `CLAUDE.md`
  **Error code reference** for the canonical list (keep in sync per
  watch-item #3).

## Extension points (iter 25)

### User commands (GDScript)

Drop a `.gd` file into `addons/godot_mcp_toolkit/user_commands/` to register
custom MCP tools. Each file must provide a `register(registry, server)` function:

```gdscript
@tool
extends RefCounted

static func register(registry, server: Node) -> void:
    registry.add("mymod.do_thing", func(params: Dictionary) -> Dictionary:
        return _cmd_do_thing(params), "full")

static func _cmd_do_thing(params: Dictionary) -> Dictionary:
    # ... your logic here ...
    return {"success": true, "data": "hello"}
```

**Rules:**
- Commands must use a `<namespace>.<action>` naming convention.
- Reserved namespaces (`scene.*`, `script.*`, `editor.*`, `node.*`,
  `runtime.*`, `resource.*`, `folder.*`, `file.*`, `signal.*`,
  `playtest.*`, `project.*`, `input_map.*`, `animation.*`, `tilemap.*`,
  `asset.*`, `save.*`, `meta.*`, `game.*`, `diff.*`, `server.*`) are
  rejected at load time.
- User commands are **profile-exempt** — they always register regardless
  of the active profile (minimal/standard/full/custom).
- User commands run with the same trust level as the plugin itself
  (they inherit FileGuard, FeatureGate, audit logging).
- Errors in user command scripts are logged but never crash the plugin.
- Restart the editor (or disable/re-enable the plugin) to pick up changes.

The TS server discovers user commands via `meta.user_commands` and
registers them as MCP tools. Claude Code receives a `tools/list_changed`
notification when new user commands are found.

### MCP Prompts, Resources, Roots (TypeScript)

The server-side exposes:
- **Prompts** — named workflow templates (`debug-scene`, `write-test`).
- **Resources** — `godot://scene/{path}`, `godot://script/{path}`,
  `godot://project/info`, `godot://roots`.
- **Hooks** — middleware pipeline wrapping every tool call. Logging hook
  is always on. Rate limiting via `GODOT_MCP_RATE_LIMIT` env var.

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
