---
name: godot-mcp-toolkit
description: >
  Best practices for building Godot 4.x games through the Godot MCP Toolkit.
  Covers tool selection, workflow patterns, error recovery, and token efficiency
  for MCP-connected agents.
when_to_use: >
  When the conversation involves building, editing, or testing a Godot project
  through MCP tools such as game_start, scene_create, node_set_property,
  discover_tools, script_write, or any godot-mcp-toolkit tool.
---

You are assisting with a Godot 4.x project through the Godot MCP Toolkit.
Follow these patterns to work efficiently, avoid common pitfalls, and
minimise wasted tool calls.

---

## 1. Quick reference

**Modes:**

| Mode | Behaviour |
|------|-----------|
| **Standard** (default) | Base tools always loaded. On-demand groups via `discover_tools`. |
| **Read-only** (`GODOT_MCP_READ_ONLY=1`) | Only tools with `readOnlyHint: true` annotations. Safe for exploration/auditing. |

**On-demand groups** — activate with `discover_tools`:
- By keyword: `discover_tools({request: "runtime"})` — fuzzy-matches groups
- By name: `discover_tools({groups: ["runtime"]})` — exact group activation
- Browse only: add `activate: false` to list tools without loading
- Deactivate: `discover_tools({reset: true})` (all) or `reset: ["tilemap"]` (selective)
- **Schema enrichment:** if activated tools are not directly callable and
  require a separate tool lookup to obtain their schemas, pass
  `include_schemas: true` to receive full parameter schemas in the response

**Feature gates** — gated tools require env vars in `.mcp.json` env block:

| Env var | Tool(s) gated |
|---------|--------------|
| `GODOT_MCP_ALLOW_EXECUTE_CODE=1` | `execute_code` |
| `GODOT_MCP_ALLOW_NODE_CALL_METHOD=1` | `node_call_method` |
| `GODOT_MCP_ALLOW_USER_SCOPE=1` | `save_read`, `save_write`, `save_delete`, `save_list` |

Toggle via the dock UI (Feature Gates checkboxes), not manual `.mcp.json`
edits. Changes require a full MCP client restart.

**Finding tools** (Claude Code tip): Use keyword search (e.g., `godot scene`)
rather than `select:` syntax. Or use full prefixed names
`select:mcp__godot-mcp-toolkit__tool_name`. Group related lookups into one query.

---

## 2. Tool selection

### By task

| Task | Tools |
|------|-------|
| Create a scene | `scene_create` -> `scene_create_node` -> `node_set_property` |
| Write a script | `script_write` -> `node_set_script` -> `editor_refresh` |
| Test a game | `game_start` -> `discover_tools({request: "runtime"})` -> runtime tools |
| Explore a project | `scene_get_tree` -> `script_read` -> `asset_list` |
| Diagnose errors | `editor_get_console` -> `script_check` -> `debugger_get_log` |
| Inspect a class | `classdb_get_info` -> `classdb_search` |

### Decision rules

- **Reading one property?** Use `node_get_property`. Reserve
  `scene_get_tree(include_properties: true)` for surveying unfamiliar scenes
  with <10 nodes. Even small scenes return hundreds of property lines.
- **Need a computed value or method call at runtime?** Use `execute_code`
  (requires `GODOT_MCP_ALLOW_EXECUTE_CODE=1`). For a single property read,
  `node_get_property` is cheaper.
- **Editor-side vs runtime-side diagnostics?** `editor_get_console` for
  compilation errors and editor warnings. `debugger_get_log` for runtime
  crashes and game-state issues.
- **Exploring an unfamiliar node class?** `classdb_get_info` returns every
  property, method, and signal with types. Follow with `node_set_property`
  to set discovered properties — covers any domain without memorising the API.
- **Finding a class by capability?** `classdb_search({pattern: "collision",
  instantiable_only: true})`. Narrow with `base_class: "Node2D"`.

---

## 3. Workflow patterns

### Scene creation -> test -> verify

1. `scene_create` — returns `root_name` and `root_path`
2. `scene_create_node` for child nodes (batch siblings in one turn)
3. `script_write` for game logic
4. `node_set_script` to attach
5. `game_start` — returns `runtime_ready: true` when the runtime connects
6. `discover_tools({request: "runtime"})` to load runtime tools
7. `runtime_get_node_state` / `input_simulate` to verify

### Dependency-aware build order

Create resources before scripts that reference them. Adapt to the project's
dependency graph — the principle is "don't reference something that doesn't
exist yet."

1. Utility scripts with no dependencies (helpers, constants, data classes)
2. Scenes (empty node trees — placeholder structure)
3. Scripts that reference scenes (use `load()` — runtime-evaluated)
4. Autoloads via `autoload_manage` (not `project_set_setting`)
5. Scripts that reference autoloads (use `class_name` for script refs)

### Batch and parallelise scene construction

Two optimisations that compose:

- **Parallel calls across nodes:** Batch all `scene_create_node` calls for
  siblings (same parent) in one turn. Only serialise parent-child pairs.
- **Batch mode within a call:** Use `node_set_property` with `batch` for
  multiple properties on one or more nodes. All changes are atomic.

Combined: scene setup goes from 30-40 sequential turns to 3-4 batched turns.

**Batch example** — set multiple properties on multiple nodes in one call:
```json
node_set_property({
  batch: [
    {node_path: "Player", property: "position", value: {type: "Vector2", x: 100, y: 200}},
    {node_path: "Player", property: "scale", value: {type: "Vector2", x: 2, y: 2}},
    {node_path: "Enemy", property: "visible", value: false}
  ]
})
```
When `batch` is present, top-level `property`/`value` are ignored.

### Autoload setup

Use `autoload_manage` to register autoloads — not `project_set_setting`
(which rejects `autoload/*` keys and redirects). Register autoloads as early
as possible so other scripts can reference them by `class_name`.

After registering, call `editor_refresh` to flush the editor cache. Console
errors that reference autoload singletons (e.g., "identifier not found") are
usually stale cache — don't re-register or rewrite scripts until you've
refreshed and re-checked.

### Playtest verification loop

After `game_start`, verify the game is in the expected state before testing:
1. `runtime_get_node_state` — check key nodes exist with correct properties
2. `input_simulate` — send inputs (keep `delay_after_ms` to 100-300ms)
3. `runtime_get_node_state` / `execute_code` — verify state changed
4. Repeat for each test scenario

**Warning:** `delay_after_ms` > 500ms is dangerous. The game world is live
during delays — enemies move, timers tick, damage accumulates.

**Verifying game state (cheapest to most expensive):**

1. `debugger_get_log` — read `print()` output. Add strategic prints in
   scripts for key state changes (score, health, wave number, game state).
   Cheapest runtime verification — tiny response, no gate required.
2. `runtime_get_node_state` — check `@export` vars and node existence.
   Design scripts with `@export` on key state vars to make them visible.
3. `runtime_get_script_vars` — all script variables, not just exports.
   Activate `runtime_advanced` group via `discover_tools`. No gate required.
4. `execute_code` — arbitrary queries on any node (requires
   `GODOT_MCP_ALLOW_EXECUTE_CODE=1` gate). Most flexible but larger
   responses than options 1-3.
5. `runtime_screenshot` — visual check. **Last resort.** Costs 5-10x more
   tokens than any text tool above. Reserve for UI layout and alignment
   verification where visual inspection is genuinely needed.

Prefer options 1-3 for state verification. Use 4 when you need computed
values or deep inspection. Use 5 only when text tools genuinely can't
answer the question (visual layout, alignment, rendering issues).

**Fast-forward testing with `runtime_set_property`:** Instead of
playing through the entire game to test late-game scenarios, set state
directly at runtime. Example — testing victory after wave 5:
```
runtime_set_property(node_path: "/root/GameManager", property: "current_wave", value: 5)
runtime_set_property(node_path: "/root/GameManager", property: "enemies_remaining", value: 0)
```
Then verify the victory screen triggers. This skips minutes of manual
play-through and dozens of `input_simulate` calls. Use it to test
win/lose conditions, edge cases, and late-game states cheaply.

### Scene instantiation

`scene_instantiate` auto-renames on name collision (Node, Node2, Node3...),
so multiple instances of the same scene work without manual renaming.

### Tilemap bulk fills

Use the `regions` parameter on tilemap tools for large area fills instead
of setting cells one at a time.

### Resource type tags

Assign textures, audio, materials, etc. via:
`node_set_property(value: {type: "Resource", path: "res://texture.png"})`.
This is the standard way to bind resources to node properties.

### Script writing patterns

- Always add `class_name` to every script — enables script-to-script
  references without `load()` or `preload()`.
- Use `@export` for properties that should be visible in the editor
  inspector and accessible via `runtime_get_node_state`.
- Declare signals with typed parameters: `signal health_changed(new_hp: int)`.
- Use `@onready var label: Label = %ScoreLabel` with unique-name nodes
  (set `unique_name: true` via `scene_create_node` or `node_set_property`).
- Never use `preload()` in MCP-generated code — use `load()` instead (it
  evaluates at runtime and tolerates creation order).

### Placeholder art

Use Godot primitives (ColorRect, Polygon2D, simple shapes) for placeholder
visuals. No need for external image generation tools.

### Partial file reads

If you wrote a script, you know its structure. Read only the function you
need (use `start_line`/`end_line` on `script_read`). Full-file reads only
for files you haven't seen, after context loss, or short files (<30 lines).

### Type wrappers for node_set_property

When setting typed properties, wrap values with a `type` tag:

| Type tag | Format | Example |
|----------|--------|---------|
| `Vector2` | `{x, y}` | `{type: "Vector2", x: 100, y: 200}` |
| `Vector3` | `{x, y, z}` | `{type: "Vector3", x: 1, y: 2, z: 3}` |
| `Vector2i` / `Vector3i` | integer `{x, y}` / `{x, y, z}` | `{type: "Vector2i", x: 10, y: 20}` |
| `Color` | `{r, g, b, a}` | `{type: "Color", r: 1, g: 0, b: 0, a: 1}` |
| `Rect2` | `{x, y, w, h}` | `{type: "Rect2", x: 0, y: 0, w: 100, h: 50}` |
| `Resource` | `{path}` | `{type: "Resource", path: "res://icon.png"}` |
| `NewResource` | `{class, properties}` | `{type: "NewResource", class: "GradientTexture2D", properties: {}}` |
| `NodePath` | `{path}` | `{type: "NodePath", path: "../Player"}` |
| `LayerMask` | `{category, layers}` | `{type: "LayerMask", category: "2d_physics", layers: [1, 2]}` |

- `Color` `a` defaults to 1.0 if omitted
- `Transform2D`: `{type: "Transform2D", x_axis: {x, y}, y_axis: {x, y}, origin: {x, y}}`
- Packed arrays: `{type: "PackedVector2Array", values: [{x: 0, y: 0}, {x: 1, y: 1}]}`
- Plain numbers, strings, and booleans don't need wrappers — only engine types do

### Signal workflow

Signals use two tools with distinct scopes:

- `signal_manage` — **editor-side**. Connects/disconnects signals in the
  scene tree. Uses UndoRedo (reversible, persists to `.tscn`). Validates
  that the signal exists on the source and the method exists on the target.
- `signal_emit` — **runtime-side** (`mode: "runtime"`). Fires signals on
  running game nodes. Connections from `signal_manage` in runtime mode are
  ephemeral — they don't persist between game sessions.

**Typical pattern:**
1. `signal_manage(action: "connect", ...)` during scene setup (editor-side)
2. `game_start` to launch the game
3. `signal_emit(mode: "runtime", ...)` to trigger signals during testing

Cross-scene connections (source and target in different scenes) work but
cannot persist — `signal_manage` returns a warning hint.

### Editor state management

- **`editor_refresh`** — Call after external file changes (`script_write`,
  manual edits). Supports targeted refresh via `file_paths` parameter.
  Essential in headless mode where filesystem scanning is async.
- **`editor_save_scene`** — Persists in-memory scene changes to disk. **Not
  automatic** — call after `scene_create_node` / `node_set_property` batches
  before switching scenes or starting a playtest.
- No need to refresh before saving — save flushes pending changes.

**Rule of thumb:** Refresh after writes, save after mutations.

### input_simulate event reference

Events use `event_type` + `event_data`. Common types:

| Event type | Key fields | Notes |
|-----------|-----------|-------|
| `key` | `keycode`, `pressed` | Use Godot key constants (e.g., `KEY_SPACE`) |
| `mouse_button` | `button_index`, `position: {x, y}`, `pressed` | `button_index`: 1=left, 2=right |
| `mouse_motion` | `position: {x, y}`, `relative: {x, y}` | For drag/hover |
| `action` | `action`, `pressed` | Matches Input Map action names |
| `click` | `position: {x, y}` | Shorthand: auto press+release |
| `click_node` | `node_path` | Click a node's center (2D/Control) |

- Wrap multiple events in an `events` array for a sequence
- `delay_after_ms` per event (keep to 100–300ms; >500ms is dangerous)
- `summary: true` (default) returns compact output

---

## 4. Profile guidance

### Standard (default)

Base tools are always available. Specialised tools live in on-demand groups
activated via `discover_tools`. Common groups:

| Group | Contains |
|-------|----------|
| `runtime_advanced` | `execute_code`, `runtime_get_script_vars`, `runtime_screenshot` |
| `signals` | `signal_manage`, `signal_emit` |
| `animation_authoring` | `animation_create`, `animation_add_track`, ... |
| `input_map` | `input_map_action`, `input_map_event` (gated) |
| `tilemap` | `tilemap_set_cells`, `tilemap_read_cells`, `tileset_edit` |
| `audio` | `audiobus_layout` |
| `3d_tools` | `mesh_create`, `mesh_surface`, `light_configure`, ... |
| `navigation` | `navigation_configure`, `navigation_bake` |

Call `discover_tools()` with no arguments to see the full catalogue.

### Power User

All tools loaded at startup. Useful when you know exactly what you need.
**Caution:** The large tool count (~99) can degrade tool-selection accuracy
in LLM contexts. Standard + `discover_tools` is generally more reliable.

### Read-only mode

Set `GODOT_MCP_READ_ONLY=1` in `.mcp.json` env vars. Only tools with
`readOnlyHint: true` annotations are visible — safe for exploration and
auditing. Both built-in and extension tools use the same annotation-driven
filter. No mutation tools available. Reconnect to exit read-only mode.

### Context management

If on-demand groups accumulate and degrade tool selection, reset them:
`discover_tools({reset: true})` deactivates all on-demand groups.
Selective: `discover_tools({reset: ["tilemap", "audio"]})`.

---

## 5. Headless mode

**Launch:** `godot --headless --editor --path <project>`

**Build:** Use MCP tools normally. No visual feedback — use `script_check` +
`editor_get_console` for validation instead of visual inspection.

**Test:** `game_start` -> `signal_emit(mode: "runtime")` ->
`runtime_get_node_state` -> `debugger_get_log`

**Constraints:**
- `editor_screenshot` returns degenerate images — rely on state queries
- `editor_refresh` is needed after external file writes (filesystem scan
  is async in headless mode)

---

## 6. Key constraints

### Never edit .tscn files directly

Always use MCP scene tools (`scene_create`, `scene_create_node`,
`node_set_property`). Direct `.tscn` edits bypass the editor's scene tree
and cause silent data loss.

### Root node path

Root node is always path `"."` — not the node name.

### Runtime state visibility

`runtime_get_node_state` shows `@export` vars only — non-exported
properties are not visible. Use `execute_code` for internal state.

### Node method invocation

`node_call_method` is editor-side only. Use `signal_emit(mode: "runtime")`
for runtime-side method invocation.

### Env var lifecycle

Changes to `GODOT_MCP_ALLOW_*` and `GODOT_MCP_PROFILE` require a full MCP
client restart. Reconnecting alone is not enough.

### .mcp.json is managed by the plugin

Do not manually edit gate state. Use the dock UI (Feature Gates checkboxes)
to toggle gates. The plugin writes gate state to a sidecar file and syncs
to `.mcp.json` automatically.

### Never screenshot for debugging logic

`runtime_screenshot` costs more tokens than 5-10 text tool calls
combined, and the image takes significantly longer to process than
structured text — slowing down your reaction time on every call.
**Never** use it to check game state, verify logic, or diagnose
errors — use `debugger_get_log`, `runtime_get_node_state`,
`runtime_get_script_vars`, or `execute_code` instead (see the
verification cost ladder in §3). Text tools return exact values
(`"gold": 150`) instantly; screenshots require visual interpretation.
Screenshots **are** the right tool for UI layout, visual alignment,
and rendering issues where text tools genuinely can't answer the
question.

### GDScript pattern: prefer load() over preload()

Use `class_name` on every script for script-to-script references (no
preload/load needed). Use `load()` for PackedScene instantiation and
resource references — it evaluates at runtime and tolerates creation order.
Never use `preload()` in generated code unless the target already exists
and there are no circular dependencies.

### GDScript pattern: use %UniqueName for node references

Mark frequently-referenced nodes with `unique_name: true` (via
`scene_create_node` or `node_set_property`). Reference them in scripts
as `@onready var label: Label = %ScoreLabel`. This survives reparenting
and restructuring. Use `$ChildName` only for structural direct children.

### Console log sources

`editor_get_console` buffer mode captures all output on Godot 4.5+
(Logger API); falls back to file-tail on 4.2-4.4 with ~200ms latency.
Use `source: "buffer"` (default) for real-time capture.

### File path conventions

- All paths must use `res://` (project scope) or `user://` (requires gate).
- Absolute OS paths (`C:\...`, `/home/...`) are rejected by the file guard.
- `..` path segments are rejected (no directory traversal).
- `scene_create` and `script_write` auto-create parent directories.
- Other tools may not — use `folder_create` for non-standard paths first.

### Node groups

Use `node_groups` to add/remove/list groups — not `node_set_property`.
Groups are not a node property and cannot be set through the property
interface. Batch mode supports multiple nodes:
`node_groups(action: "add", entries: [{node_path: ".", group: "enemies"}, ...])`.

---

## 7. Error recovery

### Debug-first protocol

When runtime behaviour is unexpected, **always diagnose before retrying**:

1. `debugger_get_log` — check what actually happened
2. Check `delay_after_ms` values in `input_simulate` (>500ms lets the game
   world advance significantly)
3. Check game state via `execute_code` (is the game still playing? is the
   player alive?)
4. THEN retry with adjusted parameters

This avoids misdiagnosis loops that waste thousands of tokens on retries
when the root cause is something else entirely (e.g., input delays letting
enemies kill the player before events process).

### Common error codes

| Code | Cause | Recovery |
|------|-------|----------|
| `GAME_NOT_RUNNING` | No game started, or it crashed | `game_start`, then `editor_get_console` if it fails again |
| `FEATURE_GATED` | Tool needs an env var | Check error message for which var. Set in `.mcp.json`, restart client |
| `NODE_NOT_FOUND` | Bad node path | Root is `"."`, children are relative. Check `scene_get_tree` |
| `PARENT_NOT_FOUND` | Parent dir doesn't exist | `scene_create` and `script_write` auto-create dirs; others may not |
| `ALREADY_PLAYING` | Game already running | `game_stop` first, or use `if_running: "return"` |
| `COMPILATION_FAILED` | Script errors | `editor_refresh` then `editor_get_console` for details |
| `LOG_UNAVAILABLE` | No log file | Use `source: "buffer"` (default) for in-memory capture |
| `LOG_BUSY` | Transient file lock | Retry in 1-2s, or use `source: "buffer"` |

---

## 8. Checkpoint pattern

For complex builds, commit progress at milestones:

**Standard checklist:**
1. Project structure + main scene
2. Game logic scripts
3. Input handling
4. Win/lose conditions
5. Visual feedback
6. Regular verification (game_start + runtime checks)
7. Headless verification (if applicable)

If a session ends mid-task, record current step and state so the next
session can continue without re-reading the entire project.

---

## 9. Token efficiency

MCP tool calls are expensive — each round trip costs tokens for the request,
the response, and the context it occupies. Minimise waste:

- **Batch properties** instead of one-at-a-time: a single `node_set_property`
  with `batch` replaces 5-10 individual calls.
- **Use `scene_get_tree` sparingly.** `include_properties: true` on even
  a small scene returns hundreds of lines. Use `node_get_property` for
  targeted reads.
- **Never screenshot for debugging logic.** `debugger_get_log` +
  `runtime_get_node_state` cost a fraction of a screenshot. Only use
  `runtime_screenshot` for UI layout, visual alignment, or rendering
  issues — never for state checks, error diagnosis, or verifying game
  logic.
- **Partial script reads.** If you wrote the script, read only the function
  you need (`start_line`/`end_line`).
- **Reset unused tool groups.** Accumulated on-demand groups degrade tool
  selection. `discover_tools({reset: true})` clears them.
- **Diagnose before retrying.** A failed playtest loop that blindly retries
  `input_simulate` 5 times wastes more tokens than one `debugger_get_log`
  call that reveals the root cause.
- **Use `classdb_get_info` with `sections`.** Requesting all sections on
  a complex class returns thousands of lines. Ask for `["properties"]` or
  `["signals"]` only.
- **Use specific keys for project settings.** `project_get_settings(prefix:
  "display")` returns hundreds of settings (including all defaults). Use
  `key: "display/window/size/viewport_width"` for a single value. If you
  need a broad survey, `Read(project.godot)` is far cheaper — it only
  contains settings that differ from defaults. If the spec already states
  the value, skip the read entirely and set it directly.

---

## Gotcha quick-reference

These are the most common sources of wasted tool calls and retries:

| Tool | Gotcha |
|------|--------|
| `input_simulate` | `delay_after_ms` > 500ms is dangerous — game world advances |
| `scene_create_node` | `node_path` param is the **parent**, not the new node's path |
| `node_set_property` | `batch` mode: top-level `property`/`value` ignored when `batch` present |
| `signal_manage` vs `signal_emit` | `manage` = editor-side connect/disconnect; `emit` = runtime-side |
| `scene_create` vs `scene_create_node` | `scene_create` = new .tscn file; `scene_create_node` = add node to open scene |
| `autoload_manage` vs `project_set_setting` | Always use `autoload_manage` for autoloads; `project_set_setting` rejects them |
| `autoload_manage` + console errors | After registering, `editor_refresh` before trusting console errors — stale cache shows false "identifier not found" |
| `execute_code` | Requires `GODOT_MCP_ALLOW_EXECUTE_CODE=1`; responses are larger than property reads |
| `editor_refresh` | Needed after external writes; especially in headless mode |
| `scene_delete` / `scene_close` | Console shows `_set_main_scene_state: Cannot convert argument 2 from Object to Object` when closing non-active tabs — this is **benign Godot engine noise** from the deferred queue, not a bug. Tabs close correctly. Do not attempt to fix or investigate this error. |
| `game_start` | `scene_path` accepts `"main"`, `"current"`, or `res://` path |
| `node_set_property` | Typed values need `{type: "Vector2", x: ...}` wrappers — plain `{x: 1, y: 2}` won't coerce |
| `node_groups` | Only way to manage groups — `node_set_property` cannot set them |
| `classdb_get_info` | Use `sections` param to limit output — full dump includes hundreds of inherited properties |
| `editor_save_scene` | Not automatic — call after mutation batches before playtest or scene switch |
| `project_get_settings` | Broad `prefix` returns hundreds of lines — use specific `key` or skip the read if spec states the value |
