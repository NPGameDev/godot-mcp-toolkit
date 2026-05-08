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
`@npgamedev/godot-mcp-server` npm package). A runtime server (`127.0.0.1:6525–6540`)
runs in debug builds for live-game introspection (Mode B).

## Godot version compatibility (iter 37)

**Minimum:** 4.2 &nbsp; **Full:** 4.5+ &nbsp; **Tested up to:** 4.6

All version-dependent API calls use `has_method()` + `call()` (dynamic
dispatch) — never direct static calls behind an `if` version check.
GDScript resolves methods at parse time; a direct call to a non-existent
method causes a parse error even inside a dead branch.

Centralized helpers in `_hub.gd`: `godot_minor()`, `get_undo_redo()`,
`get_toaster()`, `get_editor_theme()`. Command files import `_Hub` and
use these instead of calling version-dependent EditorInterface methods
directly.

**Degradation on 4.2–4.3:** UndoRedo unavailable (operations work, no undo
history); toast notifications silently skipped; TileMapLayer unavailable on
4.2 (legacy TileMap still works). **On 4.4:** everything except
`scene_close`. **On 4.5+:** full functionality.

`scene_close` is the only tool with a `godotMinVersion` gate (returns
`UNSUPPORTED` on < 4.5). The server-side version-check hook enforces
this before the call reaches the plugin.

**Future versions (4.7+):** not blocked. `GODOT_TESTED_MAX_MINOR = 6`
controls the startup warning threshold only — no functionality restricted.

**Constraint for contributors:** `Dictionary[K, V]` (typed dictionaries),
`@export_tool_button`, and `@abstract` are 4.4+/4.5+ syntax that causes
parse errors on older Godot. Do not use while minimum remains 4.2.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the full matrix.

## Tool catalogue (59 tools — iter 22 profiles + iter 26-28 classdb/diagnostics)

Iter 22 replaces the coarse lite/full flag with profiles + lazy-load groups.
Set `GODOT_MCP_PROFILE` in `.mcp.json` env block:

| Profile      | Visible tools |
|--------------|--------------|
| **standard** (default) | 26 (23 core + 3 gated stubs) + `enable_tool_group` + `extensions_refresh` = 28 in `tools/list`. 8 groups (32 tools) on demand. |
| **minimal** | 12 read-only (code-review mode) |
| **full** (Power User) | All 53 tools at startup |
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
| `scene_open`            | Open a scene in the editor. |
| `node_get_property`     | Read a property. Engine types dict-wrapped. |
| `node_set_property`     | Write a property. Engine types as `{ type, ... }`. |
| `node_get_property_list` | List properties. `mask`: "common" (default, curated), "all", or "groups". |
| `node_set_script`       | Attach/detach script. Returns `@export` properties. |
| `script_read`           | Read a GDScript / text file (`res://` only). Optional `start_line`/`end_line` for partial reads. |
| `script_write`          | Write `.gd`/`.cs`/`.gdshader`/`.gdshaderinc`. Overwrites. |
| `script_check`          | Validate GDScript file. Returns structured diagnostics (errors/warnings with line numbers). Read-only. |
| `editor_save_scene`     | Save the current edited scene. Optional `path` → save-as. |
| `editor_get_console`    | Tail editor Output panel. `level_filter`, `since_id`. |
| `project_get_settings`  | Read ProjectSettings. |
| `game_start`            | Drive editor play button. `target: "main"\|"current"\|res://*.tscn`. |
| `game_stop`             | Stop the running scene. Idempotent. |
| `runtime_screenshot`    | Capture the running game window. Returns inline PNG. |
| `input_simulate`        | Inject input into the running game. Batch events array. |
| `runtime_get_script_vars` | Get script variables for a live game node. |
| `debugger_get_log`      | Return recent output from the running game. Summary-first. |
| `folder_create`         | Create `res://` directory. Idempotent. |
| `asset_list`            | Enumerate `res://` assets with filters. |
| `classdb_get_info`      | Inspect any Godot class: properties, methods, signals, constants, inheritance. Engine + user `class_name`. |
| `classdb_search`        | Find Godot classes by inheritance and/or name pattern. Returns class list with parent + instantiability. |

### Lazy-load group tools (via `enable_tool_group`)

| Group                 | Tools |
|-----------------------|-------|
| `runtime_advanced`    | `runtime_get_node_state`, `animation_player_control` |
| `signals`             | `signal_list`, `signal_manage` (connect/disconnect), `signal_emit` |
| `animation_authoring` | `animation_keyframe` (add/remove), `animation_get_keys` |
| `input_map` (gated)   | `input_map_action` (add/remove), `input_map_event` (bind/unbind) |
| `asset_management`    | `asset_get_dependencies`, `asset_import`, `resource_delete`, `file_delete`, `scene_delete`, `scene_close`, `resource_load`, `resource_write`, `script_delete`, `folder_delete` |
| `user_data` (gated)   | `save_read`, `save_write`, `save_delete`, `save_list` |
| `scene_advanced`      | `scene_diff`, `scene_instantiate`, `tilemap_set_cells` |
| `editor_advanced`     | `editor_screenshot`, `editor_reload_scripts`, `editor_wait_for_idle` |

### Gated tools (locked stubs when disabled)

| Tool                  | Gate env var |
|-----------------------|-------------|
| `game_eval`           | `GODOT_MCP_ALLOW_GAME_EVAL` |
| `node_call_method`    | `GODOT_MCP_ALLOW_NODE_CALL_METHOD` |
| `project_set_setting` | `GODOT_MCP_ALLOW_PROJECT_SET_SETTING` |

## Multi-project support (iter 23)

Multiple Godot editors can run the plugin simultaneously. Each editor
dynamically allocates a port from the 6505–6515 range (editor) or 6525–6540
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

## Editor UI (iter 21 + 35)

- **MCP dock** — bottom-panel tab ("MCP"). Signal-driven server status (no
  polling), feature-gate toggles with .mcp.json sync indicators, polled audit
  log tail (visibility-gated, 500ms Timer). Action buttons: Regenerate Token,
  Open Full Log, Clear View. Response limit settings (script read cap, WS
  buffer size) stored in ProjectSettings `mcp/limits/`. Collapsible Info/Help
  panel with connection status, profile info, tool list grouped by domain,
  version info, multi-instance guidance, and quick-link buttons.
- **Menu items** — five entries under Project → Tools: Regenerate Token, Show
  Audit Log, Open Project Settings, Write .mcp.json, Power User Mode. All also
  registered in the Command Palette (Ctrl+Shift+P → "MCP").
- **Power User warning** — when the active profile is "full" (Power User),
  the dock displays a persistent yellow warning about unsafe tool access.
  The server also emits a one-time startup warning to stderr.
- **Profile-aware display** — the dock status line shows "Power User" instead
  of the raw internal name "full". Other profiles show their capitalized name.
- **Response limits** — configurable in the dock's "Response Limits" section.
  Script read cap (default 256 KB, min 64 KB) and WebSocket buffer (default
  1024 KB, min 256 KB). Stored in ProjectSettings `mcp/limits/`.
- **Power User Mode** — enables all feature gates via `.mcp.json` env vars
  (source of truth) and syncs PS mirror bools. Explicit `deny_<feature>`
  still overrides. Accessible from the dock, the Tools menu, the Command
  Palette, or the first-run onboarding dialog.
- **.mcp.json sync** — toggling any gate in the dock or PS Inspector
  immediately writes the corresponding env var to `.mcp.json`. The dock
  shows a warning when `.mcp.json` is missing.
- **Plugin disable cleanup** — disabling the plugin via Project Settings →
  Plugins prompts to delete the orphaned `.mcp.json` at project root.
- **Export stripping** — `EditorExportPlugin` auto-strips all
  `addons/godot_mcp_toolkit/` files from exported PCKs (iter 20 `export_strip.gd`).
- **EditorSettings** (per-user, not committed) — `mcp/personal/dock_default_visible`,
  `mcp/personal/audit_log_tail_lines`.

## Feature gates (iter 19 + 41d-ter refactor)

Seven features are gated behind explicit opt-in. By default all gates are
**off** — gated tools are absent from the MCP catalogue entirely and
plugin-side handlers return `FEATURE_DISABLED` as defence-in-depth.

**Gate model (env-var-only):** `.mcp.json` env vars are the sole source of
truth for gate state. ProjectSettings bools under
`mcp_toolkit/feature_gates/` are a **mirror UI** — changes from the dock
or PS Inspector sync bidirectionally with `.mcp.json`. There is no
dual/single gate distinction; all gates follow the same check order:

1. **Deny** (PS) — `mcp_toolkit/feature_gates/deny_<feature>` always wins
2. **Profile** (PS) — Minimal disables all; Power User enables all
3. **Env var** (.mcp.json) — `GODOT_MCP_ALLOW_*=1` enables in Standard

| Feature               | Env var                                  | PS mirror key                                      | Risk |
|-----------------------|------------------------------------------|----------------------------------------------------|------|
| `game_eval`           | `GODOT_MCP_ALLOW_GAME_EVAL`             | `mcp_toolkit/feature_gates/allow_game_eval`        | Arbitrary GDScript via Expression |
| `project_set_setting` | `GODOT_MCP_ALLOW_PROJECT_SET_SETTING`   | `mcp_toolkit/feature_gates/allow_project_set_setting` | Write arbitrary ProjectSettings keys |
| `node_call_method`    | `GODOT_MCP_ALLOW_NODE_CALL_METHOD`      | `mcp_toolkit/feature_gates/allow_node_call_method` | Method invocation on edited-scene nodes |
| `input_map_write`     | `GODOT_MCP_ALLOW_INPUT_MAP_WRITE`       | `mcp_toolkit/feature_gates/allow_input_map_write`  | Modify persistent InputMap actions |
| `read_user_scope`     | `GODOT_MCP_ALLOW_USER_SCOPE`            | `mcp_toolkit/feature_gates/allow_user_scope`       | Read/write whitelisted user:// paths |

**Dangerous-gate confirmation:** Two RCE-class features (`game_eval`,
`node_call_method`) show a confirmation dialog the first time they are
enabled in Standard profile. Once per editor session per feature.
`game_eval` is the effective security boundary for arbitrary code execution
(including OS commands and outbound HTTP via GDScript).

### How to enable

Set the env var in `.mcp.json` `env` block:
```json
{ "env": { "GODOT_MCP_ALLOW_NODE_CALL_METHOD": "1" } }
```

Or toggle the gate in the MCP Toolkit dock or Project Settings →
Mcp Toolkit → Feature Gates (changes sync to `.mcp.json` automatically).

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
2. Enable `mcp_toolkit/feature_gates/allow_user_scope` in Project Settings → Advanced.
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
- Default profile changed from "full" to "standard" (26 tools + groups on demand)

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

## Hot-reload troubleshooting

When gate or profile changes are made in the dock or PS Inspector, the
plugin writes `.mcp.json`, broadcasts `config_reloaded` to the TS bridge,
and the bridge calls `server.sendToolListChanged()`. The full diagnostic
chain logs:

1. `[MCPServer] broadcasting config_reloaded to N authed peers` (plugin)
2. `[godot-mcp] plugin notification: config_reloaded` (bridge)
3. `[godot-mcp] gate states from plugin: {...}` (server)
4. `[godot-mcp] config reloaded: old → new — N tools registered` (server)
5. `[godot-mcp] sending notifications/tools/list_changed` (server)

If all 5 log lines appear but the MCP client still shows stale tools:

- **Claude Code v2.1.0+:** The tool *registry* updates automatically via
  `tools/list_changed`. However, the deferred-tools mechanism caches
  schemas after `ToolSearch` — the model must re-run `ToolSearch` for any
  tool it previously fetched to see updated parameters or descriptions.
- **After `/compact`:** Deferred tool names can vanish entirely — run
  `ToolSearch` to rediscover them.
- **`/mcp` reconnect** forces a full re-fetch and is the most reliable
  workaround if tool state appears stale.
- **Other MCP clients** (Claude Desktop, Cursor) may require a full
  restart — they have worse `tools/list_changed` support.
- The dock shows a toast after config changes with a ToolSearch/`/mcp`
  hint when an MCP client is connected.

## Conventions when driving these tools

- **Paths always use `res://`.** No absolute filesystem paths. `FileGuard`
  rejects anything outside `res://` (plus `user://screenshots/` for
  screenshots only).
- **GDScript filenames are `snake_case`**, e.g. `res://player_controller.gd`.
- **After node mutations, call `editor_save_scene`.** Without it, changes stay
  in memory and are lost on editor close. (File-level `scene_create` /
  `scene_delete` / `script_delete` write directly to disk — no
  `editor_save_scene` needed for those.)
- **After `script_write`, call `editor_get_console`.** Lets you catch syntax
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

### Extensions (GDScript + C#)

Third-party extensions are distributable addons discovered via reflection.
Create a class extending `MCPToolkitExtension` (GDScript) or `RefCounted`
with duck typing (C#) in your own `addons/<ext>/` directory:

```gdscript
@tool
class_name MCPToolkitMyTools
extends MCPToolkitExtension

func register(registry, server: Node) -> void:
	registry.add("mymod.do_thing", _cmd_do_thing, {
		"description": "Do a thing",
		"annotations": {"readOnlyHint": true},
	})

func _cmd_do_thing(params: Dictionary) -> Dictionary:
	return {"success": true, "data": "hello"}
```

**Rules:**
- Class name must start with `MCPToolkit` (e.g., `MCPToolkitPhysicsTools`).
- Commands must use a `<namespace>.<action>` naming convention.
- Reserved namespaces (`scene.*`, `script.*`, `editor.*`, `node.*`,
  `runtime.*`, `resource.*`, `folder.*`, `file.*`, `signal.*`,
  `playtest.*`, `project.*`, `input_map.*`, `animation.*`, `tilemap.*`,
  `asset.*`, `save.*`, `meta.*`, `game.*`, `diff.*`, `server.*`,
  `extensions.*`) are rejected at load time.
- Extensions are **profile-exempt** — they always register regardless
  of the active profile (minimal/standard/full/custom).
- Extensions run with the same trust level as the plugin itself
  (they inherit FileGuard, FeatureGate, audit logging).
- Errors in extension scripts are logged but never crash the plugin.
- Restart the editor (or disable/re-enable the plugin) to pick up changes.

The TS server discovers extensions via `extensions.list` and registers
them as MCP tools with full metadata. Claude Code receives a
`tools/list_changed` notification when new extensions are found.

See `addons/godot_mcp_toolkit/docs/extending.md` for the full API.

### MCP Prompts, Resources, Roots (TypeScript)

The server-side exposes:
- **Prompts** — named workflow templates (`debug-scene`, `write-test`).
- **Resources** — `godot://scene/{path}`, `godot://script/{path}`,
  `godot://project/info`, `godot://roots`.
- **Hooks** — middleware pipeline wrapping every tool call. Logging hook
  is always on. Rate limiting via `GODOT_MCP_RATE_LIMIT` env var.

## Code style

- **`.editorconfig`** — tab indent for `.gd`/`.cfg`/`.tres`/`.tscn` (Godot
  convention), 2-space for `.json`/`.md`, UTF-8, LF line endings.
- **No external linter/formatter** — gdtoolkit (`gdformat`/`gdlint`) was
  evaluated but skipped; the Godot editor's built-in formatting and
  `.editorconfig` provide sufficient consistency for GDScript.

## CI/CD (GitHub Actions)

- **CI** (`.github/workflows/ci.yml`) — runs on push/PR to main. Installs
  Godot headless via `chickensoft-games/setup-godot`, runs
  `godot --headless --check-only` for GDScript static validation.
- **Release** (`.github/workflows/release.yml`) — runs on `v*` tag push.
  Validates tag matches `plugin.cfg` version, builds the plugin zip via
  `scripts/build-plugin-release.sh`, and uploads it as a GitHub Release
  artifact.

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

## Version sync policy

Both repos (toolkit + server) share a single semver. The version lives in:
- **Toolkit:** `addons/godot_mcp_toolkit/plugin.cfg` → `version=`
- **Server:** `package.json` → `"version"`

`scripts/get-version.sh` extracts the declared version (CI uses this to
validate sync). Future version bumps change both files and tag both repos
with the same `vX.Y.Z` tag.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev environment setup, testing
workflow, dependency policy, and PR guidelines.

## Pointer

Execution plan (all iterations, cross-repo):
`<plan-repo>/Plan/ExecutionPlan/00-index.md`.
