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

Centralized helpers in `_hub.gd`: `get_undo_redo()`,
`get_toaster()`, `get_editor_theme()`. Version checks use
`_Hub.VersionUtils.is_at_least()` / `is_at_most()` / `is_version_in_range()`.
Command files import `_Hub` and use these instead of calling
version-dependent EditorInterface methods directly.

**Degradation on 4.2–4.3:** toast notifications silently skipped
(`EditorInterface.get_editor_toaster()` is 4.4+; falls back to `push_warning()`);
TileMapLayer unavailable on 4.2 (legacy TileMap still works). UndoRedo history
**is** available here — undo goes through `EditorPlugin.get_undo_redo()`
(`EditorUndoRedoManager`, 4.0+ stable), not the 4.4+
`EditorInterface.get_editor_undo_redo()`. **On 4.4:** adds toasts; everything
except `scene_close`. **On 4.5+:** full functionality.

`scene_close` is the only tool with a `godotMinVersion` gate (returns
`UNSUPPORTED` on < 4.5). The server-side version-check hook enforces
this before the call reaches the plugin.

**Future versions (4.7+, 5.x):** not blocked. `GODOT_TESTED_MAX_VERSION = "4.6"`
controls the startup warning threshold only — no functionality restricted.

**Constraint for contributors:** `Dictionary[K, V]` (typed dictionaries),
`@export_tool_button`, and `@abstract` are 4.4+/4.5+ syntax that causes
parse errors on older Godot. Do not use while minimum remains 4.2.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the full matrix.

## Tool catalogue

Core tools (scene tree, node properties, scripting, editor operations,
playtesting, runtime inspection, asset listing) are always available.
25+ additional tool groups covering signals, animation, tilemaps, 3D,
audio, navigation, LSP, debugger, and more are loaded on demand — call
`discover_tools()` with no parameters to browse the full catalog.
`GODOT_MCP_READ_ONLY=1` in `.mcp.json` env hides all mutating tools.

When activating tool groups via `discover_tools`, always pass
`include_schemas: true` to receive full parameter schemas in the response.
This avoids a separate tool lookup for each activated tool.

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
  token and writes it to `user://addons/godot_mcp_toolkit/project_instance_<hash>/mcp_token`
  (platform-resolved — see table below). The bridge reads this file on every
  connect/reconnect and sends `{"auth":"<token>"}` as the first WebSocket
  message. Peers that don't authenticate within 2 s are closed with WS code 1008.

  | Platform | Token path                                                                               |
  |----------|------------------------------------------------------------------------------------------|
  | Windows  | `%APPDATA%\Godot\app_userdata\<project>\addons\godot_mcp_toolkit\project_instance_<hash>\mcp_token` |
  | macOS    | `~/Library/Application Support/Godot/app_userdata/<project>/addons/godot_mcp_toolkit/project_instance_<hash>/mcp_token` |
  | Linux    | `~/.local/share/godot/app_userdata/<project>/addons/godot_mcp_toolkit/project_instance_<hash>/mcp_token` |

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
  boundaries are FileGuard, token auth, and the audit log. See
  `docs/security-recommendations.md` and the `destructiveHint` MCP annotation
  on mutating tools for the caller-facing risk signals.

## Editor UI (iter 21 + 35)

- **MCP dock** — bottom-panel tab ("MCP"). Signal-driven server status (no
  polling), polled audit log tail (visibility-gated, 500ms Timer). Action
  buttons: Regenerate Token, Open Full Log, Clear View. Response limit settings
  (script read cap, WS buffer size) stored in ProjectSettings `mcp/limits/`.
  Collapsible Info/Help panel with connection status, tool list grouped by
  domain, version info, multi-instance guidance, read-only mode info, and
  quick-link buttons.
- **Menu items** — four entries under Project → Tools: Regenerate Token, Show
  Audit Log, Open Project Settings, Write .mcp.json. All also registered in
  the Command Palette (Ctrl+Shift+P → "MCP").
- **Read-only badge** — when `GODOT_MCP_READ_ONLY=1` is set in `.mcp.json`,
  the dock displays a yellow badge.
- **Response limits** — configurable in the dock's "Response Limits" section.
  Script read cap (default 256 KB, min 64 KB) and WebSocket buffer (default
  1024 KB, min 256 KB). Stored in ProjectSettings `mcp/limits/`.
- **.mcp.json sync** — the dock shows a warning when `.mcp.json` is missing.
- **Plugin disable cleanup** — disabling the plugin via Project Settings →
  Plugins prompts to delete the orphaned `.mcp.json` at project root.
- **Export stripping** — `EditorExportPlugin` auto-strips all
  `addons/godot_mcp_toolkit/` files from exported PCKs (iter 20 `export_strip.gd`).
- **EditorSettings** (per-user, not committed) — `mcp/personal/dock_default_visible`,
  `mcp/personal/audit_log_tail_lines`.

## Breaking changes vs pre-iter-22

**Tool merges (iter 22):**
- `signal_connect` + `signal_disconnect` → `signal_manage` (action: "connect"|"disconnect")
- `resource_create` + `resource_save` → `resource_write` (upsert — `type` required for new files)
- `input_map_add_action` + `input_map_remove_action` → `input_map_action` (action: "add"|"remove", `action_name` instead of `action`)
- `input_map_action_add_event` + `input_map_action_remove_event` → `input_map_event` (action: "bind"|"unbind", `action_name` instead of `action`)
- `animation_add_key` + `animation_remove_key` → `animation_keyframe` (action: "add"|"remove")

**Profile system (iter 41l-ter):**
- Profiles removed entirely. Standard is the only mode. `GODOT_MCP_PROFILE` deprecated (warning if set).
- Read-only mode (`GODOT_MCP_READ_ONLY=1`) replaces Minimal.

## Hot-reload troubleshooting

When configuration changes are made (e.g. from the dock or PS Inspector), the
plugin broadcasts `config_reloaded` to the TS bridge and the bridge calls
`server.sendToolListChanged()`. The full diagnostic chain logs:

1. `[MCPServer] broadcasting config_reloaded to N authed peers` (plugin)
2. `[godot-mcp] plugin notification: config_reloaded` (bridge)
3. `[godot-mcp] config reloaded: old → new — N tools registered` (server)
4. `[godot-mcp] sending notifications/tools/list_changed` (server)

If all 4 log lines appear but the MCP client still shows stale tools:

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
- **Phantom tab cleanup:** `scene_delete`, `file_delete` (for `.tscn`/`.scn`),
  and `folder_delete` auto-close editor tabs on 4.5+ before deleting files.
  Check `tab_closed` in the response. For `folder_delete` with multiple open
  scenes, check `stale_tabs` and call `scene_close` on each afterward.
  `scene_close` handles both active and inactive tabs.
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
- Extensions always register regardless of read-only mode.
- Extensions run with the same trust level as the plugin itself
  (they inherit FileGuard and audit logging).
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

This repo root IS a Godot 4.5 project (`project.godot` at root,
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
# 1) open THIS repo root in Godot 4.5+
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
