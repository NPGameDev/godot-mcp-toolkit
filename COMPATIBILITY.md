# Godot Version Compatibility

**Minimum supported:** Godot 4.2  
**Full functionality:** Godot 4.5+  
**Recommended:** Godot 4.5+  
**Tested up to:** Godot 4.6.2

Future Godot versions (4.7+) are not blocked. The plugin runs normally on
untested versions and logs a startup warning.

## Version tiers

| Godot version | Support level | Notes |
|---------------|---------------|-------|
| 4.0 - 4.1    | Not supported | EditorInterface is not a global singleton; would require wrapping 70+ call sites |
| **4.2**       | Core          | All tools work; some UI degradation (see below) |
| **4.3**       | Core          | TileMapLayer support added (tilemap tool auto-detects) |
| **4.4**       | Full UI       | Toast notifications and undo history restored |
| **4.5+**      | Full          | All tools and UI features available |
| 4.7+ (future) | Expected      | `has_method()` guards are forward-compatible; startup warning only |

## Tool compatibility matrix

All 55+ MCP tools work on Godot 4.2+ unless noted below.

| Tool | Min version | Behavior on older Godot |
|------|-------------|------------------------|
| `scene_close` | 4.5 | Returns `UNSUPPORTED` error with version message |
| `script_check` | 4.2 | GDScript only (`.gd`); rejects `.cs` with `INVALID_PARAMS`. `gdscript://` URIs in error messages (see below); `class_name` false positive fixed via stripping |
| `editor_reload_scripts` | 4.2 | Supports `file_paths` param for targeted O(1)-per-file mode; without params falls back to full `scan()`. Both modes work on all versions |
| All other tools | 4.2 | Fully functional (operations execute; UndoRedo history unavailable on < 4.4) |

### Degraded behavior by version

**Godot 4.2 – 4.3 (minimum):**
- UndoRedo history is unavailable for node mutations (`scene_create_node`,
  `scene_delete_node`, `scene_instantiate`), script attachment
  (`node_set_script`), signal management (`signal_manage`), animation
  keyframes (`animation_keyframe`), and tilemap edits (`tilemap_set_cells`).
  Operations still execute correctly but cannot be undone via Edit > Undo.
  `EditorUndoRedoManager` is accessed via `has_method()` dynamic dispatch
  and returns `null` on < 4.4, triggering the direct-call fallback.
- Toast notifications silently skip (no user-visible impact on tool behavior).
- `script_check` limitations apply (see section below).
- On 4.2 specifically, TileMapLayer nodes do not exist (introduced in 4.3).
  The tilemap tool still works with legacy `TileMap` nodes.

**Godot 4.4:**
- UndoRedo history works for all operations (requires proper
  `EditorUndoRedoManager` wrapping — direct property mutations bypass history).
- Toast notifications work.
- `script_check` limitations apply (see section below).
- `scene_close` still returns `UNSUPPORTED`.

**Godot 4.5+:**
- Full functionality. All tools, all UI features.
- Console capture uses the Logger API (zero-latency, in-memory ring buffer)
  instead of the file-tailing backend used on 4.2-4.4.

### EditorFileSystem indexing (all versions)

File-mutating commands (`script_write`, `resource_write`, `scene_create`,
`file_delete`, etc.) call `EditorFileSystem.update_file()` and poll
`get_file_type()` to confirm indexing before returning. An `indexed` or
`deindexed` field in the response indicates whether EditorFileSystem
acknowledged the change.

**The `indexed` field is advisory, not a functional gate.** All downstream
operations (`script_check`, `resource_load`, `scene_open`) work regardless
of the `indexed` value. Known cases where `indexed` may be `false`:

- **First file in a new directory:** `update_file()` cannot index a file
  whose parent directory is unknown to EditorFileSystem. A `scan()` fallback
  runs, but on .NET editor builds the scan may not complete within the
  3-second timeout. The second file in the same directory typically returns
  `indexed: true` because the first file's scan taught EditorFileSystem
  about the directory.
- **SVG imports:** `asset_import` may return `class: null` if the import
  pipeline hasn't finished. Call `editor_wait_for_idle` after importing.

### `folder_delete` and scene tabs (all versions)

`folder_delete` auto-switches the active editor tab away from the target
folder if the currently-edited scene is inside it. It does **not** close
individual scene tabs — rapid `open_scene_from_path` + `close_scene` calls
in a loop crash the editor via a deferred-queue race in
`EditorNode._set_main_scene_state` (signal 11). Stale tabs for deleted
scenes are cosmetic and vanish on editor restart.

### C# (.NET) editor requirement

C# projects require the Godot .NET editor build (`Godot_v*_mono_*`).
Standard builds have no .NET resource loader — `.cs` files cannot be loaded
as scripts, `[GlobalClass]` types do not register in ClassDB, and C#
runtime execution is impossible. The toolkit itself handles `.cs` file I/O
correctly on both builds; the limitation is in the Godot binary.

### `script_check` limitations (all versions)

`script_check` uses `GDScript.new().reload()` for validation.
`ResourceLoader.load()` with `CACHE_MODE_IGNORE` was evaluated as an
alternative but corrupts already-loaded scripts on all Godot versions,
crashing the editor (P-056).

The `class_name` false-positive (P-053) is mitigated by stripping the
`class_name` declaration before validation — the name is already
registered globally so the rest of the script parses correctly.

Remaining trade-off:
- **`gdscript://` URIs in error messages:** When a script has a genuine
  error, the console message references an internal `gdscript://` path
  instead of the real `res://` file path.

**Workaround:** Use `editor_get_console` with `level_filter: ["error"]` as a
cross-check — it reads diagnostics from the editor itself, which have
accurate file paths.

## UI surface compatibility matrix

| UI surface | 4.3 | 4.4 | 4.5+ | Fallback on older |
|------------|-----|-----|------|-------------------|
| Bottom-panel dock | OK | OK | OK | `add_control_to_bottom_panel()` stable across all versions |
| Server status, feature gates, audit log | OK | OK | OK | Standard Control nodes |
| Guided onboarding wizard (5-step) | OK | OK | OK | `AcceptDialog` + `add_button()` stable since 4.0 |
| Toast notifications | Degraded | OK | OK | Silently skipped; `push_warning()` to Output panel |
| Menu items (Project > Tools) | OK | OK | OK | `add_tool_menu_item()` stable since 4.0 |
| Command Palette entries | OK | OK | OK | `get_command_palette()` guarded; skipped if unavailable |
| Info/Help panel | OK | OK | OK | Standard Control nodes |
| Power User confirmation dialog | OK | OK | OK | `ConfirmationDialog` stable since 4.0 |
| Plugin disable cleanup dialog | OK | OK | OK | `popup_dialog_centered()` guarded with fallback |
| Export stripping | OK | OK | OK | `_export_file()` signature stable across 4.x |
| Inspector plugin | OK | OK | OK | `EditorInspectorPlugin` API stable since 4.0 |
| Response cap configuration | OK | OK | OK | `SpinBox` / `LineEdit` stable since 4.0 |

## Version guard implementation

All version-dependent API calls use **dynamic dispatch** to avoid GDScript
static-resolution parse errors:

```gdscript
# Safe — has_method() + call() bypasses static resolution
if EditorInterface.has_method("close_scene"):
    EditorInterface.call("close_scene")

# UNSAFE — direct call causes parse error on older Godot even inside dead branch
if Engine.get_version_info().minor >= 5:
    EditorInterface.close_scene()  # ERROR on 4.4: method not found at parse time
```

Centralized version helpers in `_hub.gd`:
- `_Hub.godot_minor()` — returns the running Godot minor version number
- `_Hub.get_undo_redo()` — returns `EditorUndoRedoManager` or `null` on < 4.4
- `_Hub.get_toaster()` — returns `EditorToaster` or `null` on < 4.4
- `_Hub.get_editor_theme()` — returns theme with fallback to `get_base_control().get_theme()`

## Server-side version awareness

The plugin sends its Godot version in the WebSocket auth handshake. The
companion `@npgamedev/godot-mcp-server` uses this to:

1. **Runtime gating** — tools with a `godotMinVersion` requirement (e.g.
   `scene_close` requires 4.5+) return an `UNSUPPORTED` error before the
   call reaches the plugin. Defence-in-depth: the plugin also checks.
2. **Startup logging** — the server logs the connected Godot version.

Environment variable `GODOT_MCP_HIDE_UNAVAILABLE=1` is reserved for future
use (hiding version-incompatible tools from `tools/list`).

## Headless mode (`--headless`)

**Tested:** Godot 4.2.0, 4.2.2, 4.3.0, 4.4.1, 4.5.0, 4.5.2, 4.6.2 on Windows.

When Godot runs with `--headless --editor`, the plugin loads, the WebSocket
server starts, and the vast majority of tools function identically to GUI mode.
Results are consistent across all tested versions.

### Detection

`_Hub.is_headless()` checks `DisplayServer.get_name() == "headless"`. Tools
that require a viewport use this guard to return `HEADLESS_UNSUPPORTED` early.

### Per-tool headless matrix

| Tool | Headless | Notes |
|------|----------|-------|
| `script_read` | ✅ | Merged: accepts optional `start_line`/`end_line` for partial reads |
| `script_write` | ✅ | |
| `script_delete` | ✅ | |
| `script_check` | ✅ | |
| `folder_create` | ✅ | |
| `folder_delete` | ✅ | |
| `file_delete` | ✅ | |
| `scene_create` | ✅ | File-based |
| `scene_delete` | ✅ | File-based |
| `scene_open` | ✅ | `EditorInterface.open_scene_from_path()` works headless |
| `scene_close` | ✅ | Requires 4.5+ (same as GUI mode) |
| `scene_get_tree` | ✅ | Requires a scene opened via `scene_open` |
| `scene_create_node` | ✅ | |
| `scene_delete_node` | ✅ | |
| `scene_instantiate` | ✅ | |
| `scene_diff` | ✅ | |
| `node_get_property` | ✅ | |
| `node_set_property` | ✅ | |
| `node_get_property_list` | ✅ | |
| `node_set_script` | ✅ | |
| `node_call_method` | ✅ | Feature-gated |
| `signal_list` | ✅ | |
| `signal_manage` | ✅ | |
| `signal_emit` | ✅ | Feature-gated |
| `resource_load` | ✅ | |
| `resource_write` | ✅ | |
| `resource_delete` | ✅ | |
| `asset_list` | ✅ | |
| `asset_get_dependencies` | ✅ | |
| `asset_import` | ✅ | |
| `save_read` | ✅ | Feature-gated |
| `save_write` | ✅ | Feature-gated |
| `save_delete` | ✅ | Feature-gated |
| `save_list` | ✅ | Feature-gated |
| `classdb_get_info` | ✅ | |
| `classdb_search` | ✅ | |
| `project_get_settings` | ✅ | |
| `project_set_setting` | ✅ | Feature-gated |
| `input_map_action` | ✅ | |
| `input_map_event` | ✅ | Feature-gated |
| `animation_keyframe` | ✅ | |
| `animation_get_keys` | ✅ | |
| `tilemap_set_cells` | ✅ | |
| `editor_save_scene` | ✅ | |
| `editor_reload_scripts` | ✅ | |
| `editor_get_console` | ✅ | |
| `editor_wait_for_idle` | ✅ | |
| `game_start` | ✅ | Game process launches; no display |
| `game_stop` | ✅ | |
| `editor_screenshot` | ❌ | Returns `HEADLESS_UNSUPPORTED`. Merged: accepts optional `node_path` for node-focused capture. |
| `runtime_screenshot` | ❌ | Requires display in game process |
| `runtime_get_node_state` | ⚠️ | Requires game with runtime server |
| `debugger_get_log` | ⚠️ | Requires game with runtime server |
| `input_simulate` | ❌ | Requires display for input events |
| `animation_player_control` | ⚠️ | Requires game with runtime server |
| `game_eval` | ⚠️ | Requires game with runtime server |

✅ = works &nbsp; ⚠️ = depends on runtime server availability &nbsp; ❌ = requires display

### CI/pipeline usage

Headless mode enables CI pipelines and SSH-only workflows. A typical CI setup:

```bash
godot --headless --editor --path /path/to/project &
# Wait for plugin to start, then use MCP tools via the server
npx @npgamedev/godot-mcp-server
```

File-based tools (scripts, resources, scenes, folders), ClassDB introspection,
and project settings all work without any display. Scene tree operations also
work — `scene_open` loads scenes programmatically and the full node/signal
tool chain functions from there.

## Forward compatibility

The `has_method()` + `call()` pattern is inherently forward-compatible.
When Godot 4.7 (or later) adds new methods, `has_method()` returns `true`
and the call succeeds — no plugin update needed for the guarded code paths.

A `GODOT_TESTED_MAX_MINOR` constant (currently `6`) controls the startup
warning threshold. Versions above this emit a `push_warning()` but do not
restrict any functionality.

## Future development constraints

- **Typed for loops** (`for x: Type in arr:`) require Godot 4.2+. Used in
  `extension_loader.gd`. Safe at current minimum.
- **Typed dictionaries** (`Dictionary[K, V]`) require Godot 4.4+. Not
  currently used in the codebase. If the minimum supported version remains
  4.2, this syntax must not appear in any `.gd` file.
- **`@export_tool_button`** requires Godot 4.4+. Same constraint.
- **`@abstract`** requires Godot 4.5+. Same constraint.
- **`EditorDock`** (4.6) is experimental. The plugin uses the deprecated
  `add_control_to_bottom_panel()` which has a compatibility shim on 4.6.

## Data format notes

Godot scene files saved in newer versions generally cannot open in older
versions (mesh compression, PackedByteArray encoding, UID references).
This is a Godot engine constraint, not a plugin limitation. The plugin
reads and writes scenes using the connected editor's native format.
