# Godot Version Compatibility

**Minimum supported:** Godot 4.2  
**Full functionality:** Godot 4.5+  
**Recommended:** Godot 4.5+  
**Tested up to:** Godot 4.7.0

Future Godot versions (4.8+) are not blocked. The plugin runs normally on
untested versions and logs a startup warning.

## Version tiers

| Godot version | Support level | Notes |
|---------------|---------------|-------|
| 4.0 - 4.1    | Not supported | EditorInterface is not a global singleton; would require wrapping 70+ call sites |
| **4.2**       | Core          | All tools work; some UI degradation (see below) |
| **4.3**       | Core          | TileMapLayer support added (tilemap tool auto-detects) |
| **4.4**       | Full UI       | Toast notifications added (`EditorInterface.get_editor_toaster()` is 4.4+) |
| **4.5+**      | Full          | All tools and UI features available |
| 4.8+ (future) | Expected      | `has_method()` guards are forward-compatible; startup warning only |

## Tool compatibility matrix

All MCP tools work on Godot 4.2+ unless noted below.

| Tool | Min version | Behavior on older Godot |
|------|-------------|------------------------|
| `scene_close` | 4.5 | Returns `UNSUPPORTED` error with version message. On 4.5+ closes active or inactive tabs; last-tab close auto-creates an empty scene |
| `script_check` | 4.2 | GDScript only (`.gd`); rejects `.cs` with `INVALID_PARAMS`. `gdscript://` URIs in error messages (see below); `class_name` false positive fixed via stripping |
| `editor_refresh` | 4.2 | Supports `file_paths` param for targeted O(1)-per-file mode; without params falls back to full `scan()`. Both modes work on all versions |
| `extensions_refresh` | 4.2 | On 4.2, **editing an existing** extension is not applied in-session (a cached read avoids an engine reimport crash — see below); the response `hint` names the extension and says to restart. Adding/removing extensions applies live. 4.3+ applies all changes live |
| `script_write` | 4.2 | `.gd` inline diagnostics (`valid`/`diagnostics`) on all versions. On Godot **< 4.4**, editing an existing `.gd` already attached to a **live** node carries a relaunch `hint` (the live instance keeps the old code until relaunch — see [Degraded behavior](#degraded-behavior-by-version)) |
| `node_call_method` | 4.2 | On **< 4.4**, an `INVALID_METHOD` whose method exists on the node's on-disk `.gd` (a stale live instance) carries a relaunch `hint`; a genuine typo does not. 4.4+ hot-reloads on a **display** editor, so the call just succeeds — but a **4.4+ headless** editor never re-instantiates the reloaded node, so the stale `hint` fires there too (headless wording: re-create the node or relaunch a display editor) |
| `lsp_*` (diagnostics, symbols, hover, completion, definition, references) | 4.2 | LSP works on 4.2+. **Multi-editor conflict detection is degraded < 4.5**: the cross-project root-mismatch check needs 4.5+, so on 4.2–4.4 give each editor a distinct `--lsp-port` + `GODOT_MCP_LSP_PORT` (see [multi-instance.md](multi-instance.md)) |
| `editor_get_console` | 4.2 | Captures runtime output (errors/warnings/prints) on all versions. **Editor parse errors** (from `editor_refresh` recompiling a script) surface only on **4.5+** (the Logger API hooks editor diagnostics); on **4.2–4.4** they are NOT written to `godot.log`, so neither `source="buffer"` nor `source="file"` can return them — use `script_check` or the `script_write` inline diagnostics instead. Multi-line errors that ARE captured (`SCRIPT ERROR: …` + `   at: <script>.gd:LINE`) are leveled as a unit, so a filename + `level_filter:["error"]` query finds the location line. 4.5+ uses the synchronous Logger (one entry per error, zero-latency) |
| `animationtree_edit` | 4.2 | All ops work on 4.2+ (set_root, add/remove_node, add/remove_transition, set_property; transitions enumerate on all versions) |
| `animationtree_list` | 4.2 | Listing works on 4.2+, but **node enumeration is 4.5+:** `AnimationNodeStateMachine.get_node_list()` is a 4.5 script API (absent 4.2-4.4), so on 4.2-4.4 `animationtree_list` returns `nodes: []` and `nodes_count` reads 0 (node *operations* via `animationtree_edit` add/remove/has still work; only listing existing nodes is unavailable). 4.5+ enumerates nodes fully |
| `input_simulate` (`send_text` event) | 4.2 | `send_text` synthesizes one `InputEventKey.unicode` per codepoint and delivers it via `Viewport.push_input` (engine-level APIs, all ≥4.0) — identical on every supported version, ungated. Non-ASCII via `String.unicode_at`; a `secret` `LineEdit`'s `text_after` is redacted |
| `debug_set_breakpoint` | 4.2 | Works on all versions **only with Godot's built-in script editor**. If the editor is configured for an **external editor** (Editor Settings → Text Editor → External, e.g. VS Code), returns `EXTERNAL_EDITOR_ACTIVE` with a steering hint — a **100% engine limitation**, not version-specific (see [External script editor](#external-script-editor-engine-limitation)) |
| All other tools | 4.2 | Fully functional. Mutating ops register UndoRedo history (undo via Edit > Undo) on all supported versions — the toolkit reaches `EditorUndoRedoManager` through `EditorPlugin.get_undo_redo()`, which is 4.0+ stable |

### External script editor (engine limitation)

**Breakpoint tools require Godot's built-in script editor — on every supported version.** Godot sets
and stores editor breakpoints on the built-in `CodeEdit` (the script editor's code widget). When the
editor is configured to use an **external editor** (Editor Settings → *Text Editor* → *External* →
"Use External Editor" enabled, pointing at e.g. VS Code), `EditorInterface.edit_script()` opens the
file in that external editor and the built-in script editor is bypassed — so there is **no `CodeEdit`
to set a breakpoint on**. `debug_set_breakpoint` detects this and returns `EXTERNAL_EDITOR_ACTIVE` with
a hint to disable the external-editor setting and retry.

**This is 100% an engine limitation, not a toolkit one** — the engine exposes no API to place a
built-in-editor breakpoint on a script it is not displaying in the built-in editor. It is **not
version-specific**: it behaves identically on Godot 4.2 through 4.7+. The remedy is to use Godot's
built-in script editor for breakpoint workflows (external editors provide their own, separate
breakpoint mechanism). Verified empirically on 4.2: with the built-in editor the breakpoint binds by
script identity (even across stale/phantom tabs); with an external editor the tool returns the clear
`EXTERNAL_EDITOR_ACTIVE` signal.

### Degraded behavior by version

**Godot 4.2 – 4.3 (minimum):**
- Toast notifications silently skip (no user-visible impact on tool behavior).
  `EditorInterface.get_editor_toaster()` is 4.4+, so the toolkit falls back to
  `push_warning()` to the Output panel here.
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
  `script_check`. On 4.2 the extension loader therefore reads through the
  editor cache (`CACHE_MODE_REUSE`), which is crash-safe but can't see the new
  edit. `extensions_refresh` returns a `hint` naming the changed extension and
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
  write is left to its diagnostics. Empirically characterised across 4.2–4.6.
  **`.gd` only** — C# (`.cs`) live reload is a different (assembly-rebuild) model
  and is not yet characterised.
  Godot 4.4+ hot-reloads promptly on a **display** editor, so no hint fires there — but a
  **headless** 4.4+ editor never re-instantiates the live node (the play/reload path is
  display-bound), so the reactive `node_call_method` hint fires headless on 4.4+ too, with
  a headless-specific message (re-create the node or relaunch a display editor; the edit is
  on disk, confirm with `script_check`).
- **GDScript LSP multi-editor — root verification needs 4.5+.** The `lsp_*` tools
  work, but the server's cross-project safety check (the workspace-root mismatch
  warning) doesn't exist before 4.5. With more than one editor open the server
  cannot detect a foreign or near-simultaneous holder of LSP port 6005, so each
  editor must use a distinct `--lsp-port` + `GODOT_MCP_LSP_PORT` (see
  [multi-instance.md](multi-instance.md)).
- **`animationtree_list` — node enumeration needs 4.5+ (4.2–4.4).**
  `AnimationNodeStateMachine.get_node_list()` is a 4.5+ script API, so on 4.2–4.4
  `animationtree_list` returns `nodes: []` and summaries report `nodes_count: 0`.
  Transitions enumerate and every node *operation* (`add_node`/`remove_node`/`has_node` via
  `add`/`remove`) works on 4.2+ — only *listing existing nodes* is unavailable. The handler
  guards the call with `has_method("get_node_list")`, so it always returns a well-formed
  result (never the malformed `INTERNAL`). 4.5+ enumerates fully.
- **`editor_get_console` — editor parse-error capture needs 4.5+ (4.2–4.4).** Godot's file
  logging (`user://logs/godot.log`, what `source="file"` reads) captures **running-game**
  output, **not** editor parse/import errors — the "red" Output-panel errors are not written
  to a file (per the engine docs; the editor-log-to-file proposal #13479 is still open). The
  4.5+ `Logger` API hooks the editor's internal error/warning stream into the in-memory
  buffer; on 4.2–4.4 there is no such hook, so editor *parse* errors are unreachable via
  `editor_get_console` (neither `source`). Use `script_check` or `script_write`'s inline
  diagnostics for parse errors instead. (Editor *runtime* warnings — `push_warning` from
  `@tool` scripts — and game output DO reach `godot.log` and are captured on all versions.)
- **Scene saves emit benign console errors (4.2 only).** On 4.2, saving a scene prints
  `"save_scene() resumed after await, but script is gone"` (and a paired *disconnect
  nonexistent connection 'process_frame'*) from the safe-save coroutine's `await
  process_frame` — a 4.2 static-coroutine lifecycle quirk.
  **The save still succeeds**; the editor may show a transient "could not save scene" notice
  but the file is written. Benign console noise; 4.3+ is unaffected. The `await` is a
  deliberate scene-save re-entrancy/crash guard, so it is not reworked for this cosmetic
  4.2-only effect.
- **Custom class docs appear lazily in the in-editor reference (4.2 only).** A
  custom public class's documentation shows in the in-editor class reference (Help →
  Search Help / F1) only **after its script has been opened/loaded once** in the session — 4.2
  generates custom-class docs lazily (on script load), whereas **4.3+** loads them eagerly at
  scan (`EditorFileSystem::_update_script_documentation`, added in 4.3). Workaround on 4.2: open
  the script once. Not a toolkit issue.

**Godot 4.4:**
- Toast notifications work (`EditorInterface.get_editor_toaster()` is 4.4+).
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
- Console capture uses the Logger API (zero-latency, in-memory ring buffer) instead of
  the file-tailing backend used on 4.2-4.4 — and, because the Logger hooks the editor's
  internal error/warning stream, it captures editor **parse/import errors** that
  `godot.log` file logging does not, so `editor_get_console` surfaces them here.
- `animationtree_list` enumerates state-machine nodes fully (`get_node_list` is 4.5+).

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

> [!IMPORTANT]
> C# projects require the Godot **.NET editor build** (`Godot_v*_mono_*`).
> Standard builds cannot load `.cs` scripts at all.

Standard builds have no .NET resource loader — `.cs` files cannot be loaded
as scripts, `[GlobalClass]` types do not register in ClassDB, and C#
runtime execution is impossible. The toolkit itself handles `.cs` file I/O
correctly on both builds; the limitation is in the Godot binary.

### `script_check` limitations (all versions)

`script_check` uses `GDScript.new().reload()` for validation.
`ResourceLoader.load()` with `CACHE_MODE_IGNORE` was evaluated as an
alternative but corrupts already-loaded scripts on all Godot versions,
crashing the editor.

The `class_name` false-positive is mitigated by stripping the
`class_name` declaration before validation — the name is already
registered globally so the rest of the script parses correctly.

Remaining trade-off:
- **`gdscript://` URIs in error messages:** When a script has a genuine
  error, the console message references an internal `gdscript://` path
  instead of the real `res://` file path.

**Workaround:** Use `editor_get_console` with `level_filter: ["error"]` as a
cross-check — it reads diagnostics from the editor itself, which have
accurate file paths.

### Quit during a pending save — one-time console noise (all versions)

Quitting the editor while a toolkit-issued save (`editor_save_scene`, or any
tool that saves a scene as a side effect) is still mid-flight can print
one-time errors in the shutdown console, in the shape of:

- `Resumed function 'save_scene()' after await, but script is gone`
- `Attempt to disconnect a nonexistent connection ... 'process_frame'`

This is accepted engine-teardown behavior, not a defect. The save path
deliberately yields for one frame before writing (part of the toolkit's
crash-safe save sequencing); a quit landing on exactly that frame tears the
scripts down before the suspended call resumes, and the engine prints the two
messages while discarding it. It is rare (the quit must hit the one yielded
frame), cosmetic, and harmless — nothing leaks and nothing crashes; the
interrupted save simply did not complete, and the editor's own quit flow still
prompts for unsaved scenes as usual. The engine exposes no queryable
"quitting" state a script could check first, so the noise cannot be guarded
away — it is safe to ignore.

### `editor_description` tooltip timer (Godot 4.3 engine issue)

Setting a node's `editor_description` arms a 0.5-second one-shot timer in the
editor's `SceneTreeEditor` that holds a **raw pointer to that node's tree row**
(`TreeItem`). On **Godot 4.3**, concurrent scene-tree churn runs a full
`tree->clear()` (4.3 rebuilds the whole scene dock on every node add/remove/move,
and has no `TreeItem` cache) that frees the armed row — even for a mutation on an
*unrelated* node — before the timer fires, so the timer dereferences freed memory
→ editor use-after-free crash (SIGSEGV). Godot **4.2** renders node tooltips
synchronously (no deferred timer) and is unaffected; Godot **4.4** added a
`SceneTreeEditor` node cache (PR #99700) that keeps `TreeItem`s alive across
rebuilds, so ordinary churn no longer frees the armed row. **4.3 is the only
version where this crashes under normal tool use.**

One narrow theoretical line-up survives on **4.4+**: the timer still binds a raw
row pointer, and *deleting the described node itself* within 0.5 s of the set
frees its cached row. That pairing is effectively unreachable at interactive pace
— only same-tick scripted `set editor_description` + `delete` of one node arms it
— and is not auto-guarded (the upstream engine fix is the real cure). If you
script that exact pairing, set the description on a node you keep, or delete a
step later.

**The toolkit prevents this automatically on 4.3.** Immediately *before* any
built-in tool writes `editor_description` (`node_set_property` scalar/batch,
`scene_create_node` inline properties), the handler drops the `SceneTreeEditor`'s
`editor_description_changed` connections on that node, so the write arms no timer.
The disconnect is **zero-latency** (no wait) and self-healing: Godot re-adds the
connection with a fresh row pointer and refreshes the tooltip synchronously on its
next scene-tree update, so nothing is lost. Connections made by *user* scripts to
the same signal are left untouched. No action needed on 4.3.

**Extension authors:** any new tool that writes `editor_description` must call
`Modules.CommandHelpers.disarm_tooltip_uaf(node, "editor_description")` immediately
before the set (a no-op off Godot 4.3) so it can't reintroduce the crash — see
[extending.md](extending.md).

## UI surface compatibility matrix

| UI surface | 4.3 | 4.4 | 4.5+ | Fallback on older |
|------------|-----|-----|------|-------------------|
| Bottom-panel dock | OK | OK | OK | 4.2–4.5: `add_control_to_bottom_panel()`. 4.6+: `add_dock()` (`EditorDock`) — capability gate flips at 4.6 |
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
preset's exclude filter.

`project.binary` additionally carries an inert `[mcp_toolkit]` config flag
(`internal/bootstrap_complete`, plus any limits/audit prefs you customise) — a
cosmetic fingerprint with **no secrets** (the auth token and registry live in
`user://`, never packed). The export plugin leaves it in place (nulling
ProjectSettings during the bake would add a crash-window risk for a cosmetic-only
gain).

A headless **CLI** export on Godot 4.4 and older can also appear to hang after the
export succeeds — an editor-session restore, not the strip plugin. Cause and
remedies:
<https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md>

### Import sidecars remain in exports (Godot 4.2 only)

On Godot 4.2, `.import` sidecars for the addon's assets and their compiled
artifacts ship in exports despite the strip plugin — in practice
`addons/godot_mcp_toolkit/icon.svg.import` plus its baked `.ctex`, about 8 KB.
Godot 4.2 never offers import sidecars to `EditorExportPlugin._export_file`, so
**no** addon can strip them on that version; 4.3+ does offer them and they strip
normally.

The residue is harmless: an orphaned texture that nothing references and nothing
loads, so the shipped build stays inert. To remove it on 4.2, add
`res://addons/godot_mcp_toolkit/*` to the export preset's exclude filter — the
same recipe the export warning suggests.

## Disabling the plugin safely

Disable the toolkit through **Project Settings → Plugins** (untick *Active*), or
remove the addon folder entirely — not by hand-editing `project.godot`. A manual
edit that empties the `[editor_plugins]` enabled list but leaves the
`[autoload] MCPRuntimeServer` line creates a **dangling autoload** that ships in
exports. It ships silently (no parse errors, and the autoload self-disables
outside the editor), so this is a cleanliness tip rather than a correctness fix —
but the Plugins toggle removes both entries correctly and is the supported path.

## Headless mode (`--headless`)

**Tested:** Godot 4.2.0, 4.2.2, 4.3.0, 4.4.1, 4.5.0, 4.5.2, 4.6.2, 4.7.0 on Windows.

When Godot runs with `--headless --editor`, the plugin loads, the WebSocket
server starts, and the vast majority of tools function identically to GUI mode.
Results are consistent across all tested versions.

### Detection

The toolkit checks `DisplayServer.get_name() == "headless"`. Tools
that require a viewport use this guard to return `HEADLESS_UNSUPPORTED` early.

### Per-tool headless matrix

The matrix below covers the core tool surface as audited end-to-end in
headless mode. Tools added since that audit (the LSP, debugger, 3D, and
tileset groups among others) follow the same detection rule — file-based
operations work, viewport-dependent ones return `HEADLESS_UNSUPPORTED` —
but have not been individually re-audited headless yet.

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
| `node_call_method` | ✅ | Works; but a **4.4+ headless** editor never re-instantiates a reloaded node, so a call to a freshly-added method returns `INVALID_METHOD` + a headless stale `hint` (re-create or relaunch). See the live-reload note above |
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
| `editor_get_console` | ✅ | Captures runtime output headless; but a headless editor doesn't revalidate scripts, so editor **parse** errors aren't captured — an error-capture query (`level_filter:["error"]` or a `text_filter`) attaches a `headless_hint` steering to `script_check`. See the parse-capture note above |
| `editor_wait_for_idle` | ✅ | |
| `game_start` | ❌ | Returns `HEADLESS_UNSUPPORTED` — the game process can't launch without a display, so the runtime connection (the running game) never establishes. Use `script_check` / scene inspection / `editor_get_console` to verify |
| `game_stop` | ✅ | |
| `editor_screenshot` | ❌ | Returns `HEADLESS_UNSUPPORTED`. Merged: accepts optional `node_path` for node-focused capture. |
| `runtime_screenshot` | ❌ | Requires display in game process |
| `runtime_get_node_state` | ⚠️ | Requires game with runtime server |
| `debugger_get_log` | ⚠️ | Requires game with runtime server |
| `input_simulate` | ❌ | Requires display for input events |
| `animation_player_control` | ⚠️ | Requires game with runtime server |
| `execute_code` | ⚠️ | Game context requires a game with the runtime server |

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

## macOS GUI-launch (Node / PATH)

Modern GUI-launched MCP clients (Claude Desktop, Cursor.app, VS Code.app) capture
your login shell's environment and resolve a bare `npx` to a version-manager Node
themselves, so the standard config connects whether you launch the client from
Finder/Dock or a terminal. The toolkit emits the **standard `npx`** command on macOS
— the same shape as Linux (Windows uses `cmd /c npx`); there is no macOS-specific
resolution.

If a macOS client won't connect, launch it from a terminal to see its startup error,
confirm `.mcp.json` is present at the project root, and confirm Node 22+ is
installed. Full diagnosis + fallbacks (nvm in `~/.zprofile`, the nodejs.org
installer, `GODOT_MCP_DEV_SERVER_PATH`) are in
[advanced_configuration.md](advanced_configuration.md) (*macOS* section). Per-client
setup for other MCP clients lives in the companion server's client guide:
<https://github.com/NPGameDev/godot-mcp-server/blob/main/docs/mcp-clients.md>.

## Forward compatibility

The `has_method()` + `call()` pattern is inherently forward-compatible.
When Godot 4.8 (or later) adds new methods, `has_method()` returns `true`
and the call succeeds — no plugin update needed for the guarded code paths.

A `GODOT_TESTED_MAX_VERSION` constant (currently `"4.7.0"`) controls the startup
warning threshold. Versions above this emit a `push_warning()` but do not
restrict any functionality.

## Data format notes

Godot scene files saved in newer versions generally cannot open in older
versions (mesh compression, PackedByteArray encoding, UID references).
This is a Godot engine constraint, not a plugin limitation. The plugin
reads and writes scenes using the connected editor's native format.
