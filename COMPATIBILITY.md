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
| **4.2**       | Core          | All tools work; some UI degradation (see below); no automated CI validation (see [CI limitations](#ci-limitations)) |
| **4.3**       | Core          | TileMapLayer support added (tilemap tool auto-detects) |
| **4.4**       | Full UI       | Toast notifications and undo history restored |
| **4.5+**      | Full          | All tools and UI features available |
| 4.7+ (future) | Expected      | `has_method()` guards are forward-compatible; startup warning only |

## Tool compatibility matrix

All 55+ MCP tools work on Godot 4.2+ unless noted below.

| Tool | Min version | Behavior on older Godot |
|------|-------------|------------------------|
| `scene_close` | 4.5 | Returns `UNSUPPORTED` error with version message. On 4.5+ closes active or inactive tabs; last-tab close auto-creates an empty scene |
| `script_check` | 4.2 | GDScript only (`.gd`); rejects `.cs` with `INVALID_PARAMS`. `gdscript://` URIs in error messages (see below); `class_name` false positive fixed via stripping |
| `editor_refresh` | 4.2 | Supports `file_paths` param for targeted O(1)-per-file mode; without params falls back to full `scan()`. Both modes work on all versions |
| `extensions_refresh` | 4.2 | On 4.2, **editing an existing** extension is not applied in-session (a cached read avoids an engine reimport crash — see below); the response `hint` names the extension and says to restart. Adding/removing extensions applies live. 4.3+ applies all changes live |
| `script_write` | 4.2 | `.gd` inline diagnostics (`valid`/`diagnostics`) on all versions. On Godot **< 4.4**, editing an existing `.gd` already attached to a **live** node carries a relaunch `hint` (the live instance keeps the old code until relaunch — see [Degraded behavior](#degraded-behavior-by-version)) |
| `node_call_method` | 4.2 | On **< 4.4**, an `INVALID_METHOD` whose method exists on the node's on-disk `.gd` (a stale live instance) carries a relaunch `hint`; a genuine typo does not. 4.4+ hot-reloads, so the call just succeeds |
| `lsp_*` (diagnostics, symbols, hover, completion, definition, references) | 4.2 | LSP works on 4.2+. **Multi-editor conflict detection is degraded < 4.5**: the cross-project root-mismatch check needs 4.5+, so on 4.2–4.4 give each editor a distinct `--lsp-port` + `GODOT_MCP_LSP_PORT` (see `docs/multi-instance.md`) |
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
- **Extension hot-reload — editing an existing extension needs a restart (4.2
  only).** Adding a new extension and removing one both apply live, but *editing*
  an already-loaded extension's tools is not reflected in-session. Loading a
  freshly-edited `@tool` script fresh (`CACHE_MODE_IGNORE`) while
  `EditorFileSystem` is still reimporting it spawns a second, unregistered,
  synchronous parallel load during global-class registration and natively crashes
  the 4.2 editor — the same `CACHE_MODE_IGNORE` hazard already noted for
  `script_check` (P-056). On 4.2 the extension loader therefore reads through the
  editor cache (`CACHE_MODE_REUSE`), which is crash-safe but can't see the new
  edit. `extensions.refresh` returns a `hint` naming the changed extension and
  telling you to restart the editor; a `push_warning` also shows in the Output
  panel. Godot 4.3+ applies edits live (validated on 4.5).
- **Live attached-script reload — editing a script bound to a running instance
  needs a relaunch (4.2 + 4.3).** A **distinct** boundary from the extension
  hot-reload above (which is 4.2→4.3): live scene-node attached-script reload is
  the **4.3→4.4** boundary. On 4.2 and 4.3, after `script_write` edits a `.gd` that
  is already attached to a live node, that instance keeps the OLD code — *added
  members* surface as `INVALID_METHOD`, and *changed method bodies* run silently
  with the old behaviour and **no error**. `editor_refresh`, re-`node_set_script`,
  and even creating a brand-new node all keep the stale code; only relaunching the
  editor (or disabling then re-enabling the plugin) picks up the edit. The toolkit
  surfaces this on < 4.4 as a `hint`: **proactively** on the `script_write`
  response (an existing `.gd` that compiled OK) and **reactively** on a
  `node_call_method` `INVALID_METHOD` whose method exists on the on-disk script. A
  genuine typo (method absent on disk) gets no such hint, and a compile-failed
  write is left to its diagnostics. Empirically characterised across 4.2–4.6; see
  `Insights/stale-live-instance-method-hazard.md`. **`.gd` only** — C# (`.cs`) live
  reload is a different (assembly-rebuild) model and is not yet characterised
  (`Plan/Ideas/PostRelease/2026-06-11-csharp-live-instance-staleness-research.md`).
  Godot 4.4+ hot-reloads promptly, so no hint fires.
- **GDScript LSP multi-editor — root verification needs 4.5+.** The `lsp_*` tools
  work, but the server's cross-project safety check (the workspace-root mismatch
  warning) doesn't exist before 4.5. With more than one editor open the server
  cannot detect a foreign or near-simultaneous holder of LSP port 6005, so each
  editor must use a distinct `--lsp-port` + `GODOT_MCP_LSP_PORT` (see
  `docs/multi-instance.md`).

**Godot 4.4:**
- UndoRedo history works for all operations (requires proper
  `EditorUndoRedoManager` wrapping — direct property mutations bypass history).
- Toast notifications work.
- `script_check` limitations apply (see section below).
- `scene_close` returns `UNSUPPORTED`.
- `scene_delete`/`file_delete`: non-active open scene tabs become phantoms
  with a warning; active scene deletion is blocked (`EDITED_SCENE`).
- GDScript LSP multi-editor: root verification needs 4.5+ (see the 4.2–4.3 note);
  a multi-editor LSP setup on 4.4 still needs a distinct `--lsp-port` +
  `GODOT_MCP_LSP_PORT`.

**Godot 4.5+:**
- Full functionality. All tools, all UI features.
- GDScript LSP multi-editor conflict detection fully supported (workspace-root
  verification catches a wrong-project or non-registry holder of port 6005).
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

### Phantom tab cleanup (scene/file/folder delete)

`scene_delete`, `file_delete` (for `.tscn`/`.scn`), and `folder_delete` all
attempt to close editor tabs for scenes being deleted, preventing phantom
tabs that silently recreate files on save (godot#44123).

**Godot 4.5+:** tabs are closed automatically via `close_scene_tab_safe()`.
The response includes `tab_closed: true`. For `folder_delete` with exactly
one scene inside, that tab is closed cleanly. Multiple scene tabs cannot be
closed in a loop (deferred-queue crash, signal 11) — the response returns a
`stale_tabs` array; call `scene_close` on each afterward (MCP round-trip
provides safe sequencing).

**Active tab after close:** closing a non-active tab switches to that tab
first, then closes it. Godot auto-switches to an adjacent tab afterward —
the previously-active tab is **not** restored (restoring triggers a benign
but noisy `_set_main_scene_state` deferred-queue error in the engine).

**Godot 4.2–4.4:** no `close_scene()` API exists. Deleting a non-active
open scene proceeds with a phantom warning (`tab_closed: false`, `warnings`
array). Deleting the **active** scene returns `EDITED_SCENE` error (the
phantom would be the focused tab, and Ctrl+S would recreate the file).
`folder_delete` uses the switch-away strategy and returns `stale_tabs` +
`warnings`.

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
| Server status, audit log | OK | OK | OK | Standard Control nodes |
| Guided onboarding wizard (3-step) | OK | OK | OK | `AcceptDialog` + `add_button()` stable since 4.0 |
| Toast notifications | Degraded | OK | OK | Silently skipped; `push_warning()` to Output panel |
| Menu items (Project > Tools) | OK | OK | OK | `add_tool_menu_item()` stable since 4.0 |
| Command Palette entries | OK | OK | OK | `get_command_palette()` guarded; skipped if unavailable |
| Info/Help panel | OK | OK | OK | Standard Control nodes |
| Plugin disable cleanup dialog | OK | OK | OK | `popup_dialog_centered()` guarded with fallback |
| Export stripping (non-script + Text mode) | OK | OK | OK | 4.2 strips all modes (no binary tokens); see below |
| Binary-token script leak warning | Output log | Export dialog | Export dialog | 4.2: n/a (no binary-token mode) |
| Inspector plugin | OK | OK | OK | `EditorInspectorPlugin` API stable since 4.0 |
| Response cap configuration | OK | OK | OK | `SpinBox` / `LineEdit` stable since 4.0 |

## Export stripping (binary-token script gap)

The addon's export plugin removes addon/extension **non-script** files and
`res://.mcp.json` and nulls the runtime autoload in **every** export mode, and it
removes addon/extension **scripts** when the preset's *Script Export Mode* is
**Text**. It does **not** remove scripts in **Binary tokens** / **Binary tokens
(compressed)** modes (Godot's default on 4.3+): the engine compiles each `.gd` to
`.gdc` in the built-in GDScript export plugin — which runs **before** ours — so the
scripts ship as inert, orphaned `.gdc`. The leak is cosmetic (orphaned +
lazy-loaded → never executed; the runtime autoload is nulled and additionally
self-gates on `not OS.has_feature("editor")`). There is no safe in-addon strip:
`EditorExportPreset.set_exclude_filter` is unbound to GDScript (still so in 4.6 —
godotengine/godot#4054). The plugin therefore **warns** instead of stripping.

The warning fires only when a binary-token mode leaks addon/extension scripts, and
its delivery depends on the Godot version (`add_message` / `get_export_platform`
were bound to GDScript in 4.4):

| Godot | Binary-token leak? | Warning delivery |
|-------|--------------------|------------------|
| 4.2 | No — no binary-token mode; scripts ship as text and are stripped | none (never fires) |
| 4.3 | Yes | `push_warning()` → **Output / stderr log** (`add_message` unbound until 4.4) |
| 4.4 | Yes | `EditorExportPlatform.add_message()` → **export dialog** |
| 4.5+ | Yes | `add_message()` → **export dialog** |

For a fully clean build in a binary-token mode, set Script Export Mode to **Text**
or add `res://addons/godot_mcp_toolkit/*` (and each extension `.gd` path) to the
preset's exclude filter. See ADR 0006.

`project.binary` additionally carries an inert `[mcp_toolkit]` config flag
(`internal/bootstrap_complete`, plus any limits/audit prefs you customise) — a
cosmetic fingerprint with **no secrets** (the auth token and registry live in
`user://`, never packed). `export_strip` leaves it in place (nulling ProjectSettings
during the bake would add a crash-window risk for a cosmetic-only gain); an optional
strip is a post-1.0 consideration.

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
- `_Hub.VersionUtils.is_at_least(ver, min)` / `is_at_most(ver, max)` — single-bound version checks
- `_Hub.VersionUtils.is_version_in_range(ver, min, max)` — range version check (used by command registry)
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
| `node_call_method` | ✅ | |
| `signal_list` | ✅ | |
| `signal_manage` | ✅ | |
| `signal_emit` | ✅ | |
| `resource_load` | ✅ | |
| `resource_write` | ✅ | |
| `resource_delete` | ✅ | |
| `asset_list` | ✅ | |
| `asset_get_dependencies` | ✅ | |
| `asset_import` | ✅ | |
| `save_read` | ✅ | |
| `save_write` | ✅ | |
| `save_delete` | ✅ | |
| `save_list` | ✅ | |
| `classdb_get_info` | ✅ | |
| `classdb_search` | ✅ | |
| `project_get_settings` | ✅ | |
| `project_set_setting` | ✅ | |
| `input_map_action` | ✅ | |
| `input_map_event` | ✅ | |
| `animation_keyframe` | ✅ | |
| `animation_get_keys` | ✅ | |
| `tilemap_set_cells` | ✅ | |
| `editor_save_scene` | ✅ | |
| `editor_refresh` | ✅ | |
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

A `GODOT_TESTED_MAX_VERSION` constant (currently `"4.6"`) controls the startup
warning threshold. Versions above this emit a `push_warning()` but do not
restrict any functionality.

## CI limitations

CI runs `scripts/test_framework/validate_gdscript.sh` (editor-headless +
per-file script runner) on Godot 4.3+. **Godot 4.2 is excluded from the
CI matrix entirely** because its editor scan aborts on `class_name`
cross-references before completing — all detected errors are false
positives, not real script problems. This is a chicken-and-egg bug in
Godot 4.2's GDScript module (fixed in 4.3): the scanner needs the class
cache to resolve `class_name` identifiers, but the class cache is built
by the scan. Both standard and .NET editor builds have the same issue.

4.2 compatibility is verified via local sweep + smoke tests (mandatory on
large toolkit iterations, optional on medium ones). Headless unit tests
also cannot run on 4.2 in CI (same `class_name` root cause), but work
locally when the editor has generated the class cache.

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
