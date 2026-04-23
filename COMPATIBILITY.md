# Godot Version Compatibility

**Minimum supported:** Godot 4.3  
**Full functionality:** Godot 4.5+  
**Recommended:** Godot 4.5+  
**Tested up to:** Godot 4.6

Future Godot versions (4.7+) are not blocked. The plugin runs normally on
untested versions and logs a startup warning.

## Version tiers

| Godot version | Support level | Notes |
|---------------|---------------|-------|
| 4.0 - 4.2    | Not supported | EditorInterface API shape differs too much |
| **4.3**       | Core          | All tools work; some UI degradation (see below) |
| **4.4**       | Full UI       | Toast notifications and undo history restored |
| **4.5+**      | Full          | All tools and UI features available |
| 4.7+ (future) | Expected      | `has_method()` guards are forward-compatible; startup warning only |

## Tool compatibility matrix

All 55+ MCP tools work on Godot 4.3+ unless noted below.

| Tool | Min version | Behavior on older Godot |
|------|-------------|------------------------|
| `scene_close` | 4.5 | Returns `UNSUPPORTED` error with version message |
| All other tools | 4.3 | Fully functional |

### Degraded behavior by version

**Godot 4.3 (minimum):**
- UndoRedo history is unavailable for node mutations (`scene_create_node`,
  `scene_delete_node`, `scene_instantiate`), script attachment
  (`node_set_script`), signal management (`signal_manage`), animation
  keyframes (`animation_keyframe`), and tilemap edits (`tilemap_set_cells`).
  Operations still execute correctly but cannot be undone via Edit > Undo.
- Toast notifications silently skip (no user-visible impact on tool behavior).

**Godot 4.4:**
- UndoRedo history works for all operations.
- Toast notifications work.
- `scene_close` still returns `UNSUPPORTED`.

**Godot 4.5+:**
- Full functionality. All tools, all UI features.

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

## Forward compatibility

The `has_method()` + `call()` pattern is inherently forward-compatible.
When Godot 4.7 (or later) adds new methods, `has_method()` returns `true`
and the call succeeds — no plugin update needed for the guarded code paths.

A `GODOT_TESTED_MAX_MINOR` constant (currently `6`) controls the startup
warning threshold. Versions above this emit a `push_warning()` but do not
restrict any functionality.

## Future development constraints

- **Typed dictionaries** (`Dictionary[K, V]`) require Godot 4.4+. Not
  currently used in the codebase. If the minimum supported version remains
  4.3, this syntax must not appear in any `.gd` file.
- **`@export_tool_button`** requires Godot 4.4+. Same constraint.
- **`@abstract`** requires Godot 4.5+. Same constraint.
- **`EditorDock`** (4.6) is experimental. The plugin uses the deprecated
  `add_control_to_bottom_panel()` which has a compatibility shim on 4.6.

## Data format notes

Godot scene files saved in newer versions generally cannot open in older
versions (mesh compression, PackedByteArray encoding, UID references).
This is a Godot engine constraint, not a plugin limitation. The plugin
reads and writes scenes using the connected editor's native format.
