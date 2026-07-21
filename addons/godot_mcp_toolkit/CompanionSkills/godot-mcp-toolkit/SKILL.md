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

**The tool surface:** a lean **startup surface** is visible the moment you
connect (the eager tools plus `discover_tools` / `extensions_refresh`); it
expands to the **full surface** on demand — call `discover_tools` to activate the
group a task needs. **Read-only mode** (`GODOT_MCP_READ_ONLY=1` in your
`.mcp.json` env block, or the dock's read-only toggle) hides every mutating tool
on top of whichever surface is active — safe for exploration and auditing.

**On-demand groups** — activate with `discover_tools`:
- `discover_tools({request: ["runtime_advanced", "tilemap"]})` — pass one or
  more group names or keywords in a single call
- Browse only: add `activate: false` to list a group's tools without loading
- Deactivate: `discover_tools({reset: true})` (all) or `reset: ["tilemap"]`
- **Schema enrichment:** only if you activated a group but the new tools aren't
  showing in your tool list, call `discover_tools` again with
  `include_schemas: true` to get their parameter schemas inline
- **Short keywords:** fuzzy search matches short terms (`"3d"`, `"2d"`, `"ui"`,
  `"ai"`) only against explicit keywords, not by substring. If a short keyword
  returns nothing, use the exact group name

**High-risk tools** — some tools carry a `destructiveHint: true` MCP annotation
so agents see the risk signal. They are always available (no opt-in needed); you
decide whether to use them based on context.

**Finding tools** (Claude Code tip): use keyword search (e.g. `godot scene`)
rather than `select:` syntax, or the full prefixed name
`select:mcp__godot-mcp-toolkit__tool_name`. Group related lookups into one query.

---

## 2. Tool selection

### By task

| Task | Tools |
|------|-------|
| Create a scene | `scene_create` -> `scene_open` -> `scene_create_node` -> `node_set_property` |
| Edit an existing script | `script_edit` (exact `old_string` -> `new_string`) -> `script_check` |
| Write a new script | `script_write` -> `node_set_script` |
| Test a game | `game_start` -> `discover_tools({request: "runtime"})` -> runtime tools |
| Explore a project | `scene_get_tree` -> `script_read` -> `asset_list` |
| Diagnose errors | `editor_get_console` -> `script_check` -> `lsp_project_diagnostics` (`lsp_code_analysis` group) -> `debugger_get_log` |
| Navigate/inspect code | `lsp_definition` / `lsp_references` / `lsp_symbols` (`lsp_code_navigation` / `lsp_code_analysis` groups) |
| Inspect a class | `classdb_get_info` -> `classdb_search` (`classdb` group) |

### Decision rules

- **Reading one property?** Use `node_get_property` — cheaper than any tree walk.
- **Surveying a tree?** `scene_get_tree` defaults to `max_depth: 2` (use `-1` for
  the full tree, so you don't act on a truncated view). Prefer a filtered
  `scene_query` (`offset`/`limit`, default 50, clamped to 200) over
  `scene_get_tree(include_properties: true)` for surveys — paged reads carry a
  `returned`/`has_more` envelope; re-query from `offset: 0` if the tree changed.
- **Need a computed value or method call at runtime?** Use `execute_code`. For a
  single property read, `node_get_property` is cheaper.
- **Editor vs runtime diagnostics?** `editor_get_console` for compilation errors
  and editor warnings; `debugger_get_log` for runtime crashes and game state.
- **Control layout?** `control_set_layout` sets an anchor preset plus optional
  margins in one call and returns the final rect.
- **Exploring an unfamiliar node class?** `classdb_get_info` (`classdb` group)
  returns every property, method, and signal with types. Follow with
  `node_set_property` to set what you find — covers any domain without
  memorising the API.
- **Finding a class by capability?** `classdb_search({pattern: "collision",
  instantiable_only: true})`. Narrow with `base_class: "Node2D"`.

---

## 3. Workflow patterns

### Scene creation -> test -> verify

1. `scene_create` — saves a new `.tscn` to disk; it does **not** open it
2. `scene_open` — make it the active scene (required before adding nodes)
3. `scene_create_node` for child nodes (batch siblings in one turn; inline
   `properties` supported — on partial failure the node is kept, check
   `properties_failed`)
4. `script_write` (new file) / `script_edit` (existing) → `node_set_script`
5. `editor_save_scene` to persist the mutations
6. `game_start` — returns `runtime_ready: true` when the runtime connects
7. `discover_tools({request: "runtime"})` → `runtime_get_node_state` /
   `input_simulate` to verify

**Dependency-aware build order.** Create resources before scripts that reference
them — "don't reference something that doesn't exist yet." Adapt to the project's
dependency graph: utility scripts (no deps) → scenes (empty node trees) → scripts
referencing scenes (use `load()`, runtime-evaluated) → autoloads via
`autoload_manage` (not `project_set_setting`) → scripts referencing autoloads (by
`class_name`).

### Batch and parallelise scene construction

Two optimisations that compose: **batch calls across siblings** — all
`scene_create_node` calls for one parent in a single turn (only serialise
parent-child pairs); **batch mode within a call** — `node_set_property` with
`batch` sets many properties on one or more nodes atomically. Independent **read**
calls can also go out together in one turn (reads bypass the mutation queue; only
order-dependent mutations need sequencing). Combined, scene setup drops from
30-40 sequential turns to 3-4 batched turns.

```json
node_set_property({
  batch: [
    {node_path: "Player", property: "position", value: {type: "Vector2", x: 100, y: 200}},
    {node_path: "Enemy", property: "visible", value: false}
  ]
})
```
When `batch` is present, top-level `property`/`value` are ignored.

**Autoload setup.** Use `autoload_manage` to register autoloads — not
`project_set_setting` (which rejects `autoload/*` keys and redirects). Register as
early as possible so other scripts can reference them by `class_name`. After
registering, call `editor_refresh` (`editor_advanced` group) to flush the editor
cache: console errors that reference autoload singletons (e.g. "identifier not
found") are usually stale cache — don't re-register or rewrite scripts until
you've refreshed and re-checked.

### Playtest verification loop

After `game_start`: verify key nodes exist with the right properties →
`input_simulate` to send inputs (`delay_after_ms` 100-300ms) → verify state
changed → repeat per scenario. **Warning:** `delay_after_ms` > 500ms is dangerous
— the game world is live during delays, so enemies move and timers tick.

**Verifying game state (cheapest to most expensive):**

1. `debugger_get_log` — read `print()` output (available from startup; works
   during gameplay AND after a crash; `limit` / `text_filter`). Add strategic
   prints for key state (score, health, wave). Cheapest runtime check.
2. `runtime_get_node_state` (`runtime_advanced` group) — primarily `@export`
   vars and inspector-visible fields; put `@export` on key state vars.
3. `runtime_get_script_vars` — all script variables, not just exports (available
   from startup; `visibility` filter: `public`/`private`/`all`).
4. `execute_code` — arbitrary expressions on any node (available from startup;
   expression-only). Most flexible, larger responses than 1-3.
5. `runtime_screenshot` — visual check. **Last resort**, 5-10x the tokens of a
   text tool. Use `image_detail: "low"`/`"mid"` to save budget; on
   `RUNTIME_WINDOW_MINIMIZED`, retry with `force_foreground_game: true`.

Prefer 1-3; use 4 for computed values; use 5 only for visual layout, alignment,
or rendering questions text tools can't answer.

### Fast-forward testing with `runtime_set_property`

Instead of playing through the whole game, set late-game state directly.
`runtime_set_property` (`runtime_advanced` group) supports compound paths
(`position:x`). Example — test victory after wave 5:
```
runtime_set_property(node_path: "/root/GameManager", property: "current_wave", value: 5)
runtime_set_property(node_path: "/root/GameManager", property: "enemies_remaining", value: 0)
```
Then verify the victory screen triggers — skipping minutes of play and dozens of
`input_simulate` calls.

**Scene instantiation.** `scene_instantiate` (`scene_advanced` group) auto-renames
on name collision, so multiple instances of one scene work without manual
renaming. Its `instances: [{name?, position?, rotation?, scale?, properties?}]`
batch spawns N copies with transforms in one call.

**Tilemap bulk fills.** Use the `regions` parameter on `tilemap_set_cells` for
large rectangular fills instead of listing cells one at a time (can be combined
with `cells`). Read cells back with `tilemap_read_cells` (both in the `tilemap`
group).

### Script writing patterns

- Always add `class_name` — enables script-to-script references without
  `load()`/`preload()`.
- `@export` for properties visible in the inspector and via
  `runtime_get_node_state`.
- Declare signals with typed parameters: `signal health_changed(new_hp: int)`.
- `@onready var label: Label = %ScoreLabel` with unique-name nodes.
- **Prefer `script_edit` for changes to an existing script** — a surgical
  `old_string` -> `new_string` swap that keeps undo history and returns inline
  diagnostics. Use `script_write` for new files.
- **Use `script_write` / `script_edit` for EVERY script file** — including scratch
  drafts, experiments, and throwaway managers, never a native file-write tool. The
  MCP tools compile-check the code and register it with the running editor; a raw
  filesystem write does neither, so it is never the better choice in a live project.

**Placeholder art.** Use Godot primitives (ColorRect, Polygon2D, simple shapes)
for placeholder visuals. For quick placeholder assets, `texture_generate` /
`sound_generate` (`placeholders` group) exist — no external image tools needed.

### Type wrappers for `node_set_property`

Engine types need a `{type: ...}` wrapper; plain numbers, strings, and booleans
don't. The essentials — bind a resource, position, or colour:

- Resource: `{type: "Resource", path: "res://texture.png"}` (textures, audio, materials)
- Vector2: `{type: "Vector2", x, y}`
- Color: `{type: "Color", r, g, b, a}` (`a` defaults to 1.0)

Unknown `type` tags are rejected with the supported list. Full table — packed
arrays, `Transform2D`/`Transform3D`, `NewResource`, `NodePath`, `LayerMask`,
compound paths — in `references/type-wrappers.md`.

### Signal workflow

- `signal_manage` — **editor-time** connect/disconnect (CONNECT_PERSIST — saved
  in `.tscn`, survives save/load; idempotent). Validates the signal exists on
  the source and the method on the target.
- `signal_list` — inspect signals and their connections (`include_connections`).
- `signal_emit` — fire a signal **now**: `channel: "editor"` (default, edited
  scene) or `channel: "runtime"` (the running game — needs the `signals` group
  activated and a running game).

**Typical pattern:** connect during setup with `signal_manage` -> `game_start`
-> `signal_emit(channel: "runtime")` to trigger during testing. Cross-scene
connections (source and target in different scenes) cannot persist —
`signal_manage` returns a hint steering you to `_ready()` code instead.

**Editor state management — refresh after external writes, save after
mutations.** `editor_refresh` (`editor_advanced` group) is for files created
**outside** MCP tools (native Write/Bash) and after autoload registration
(stale-cache errors); targeted `file_paths` is O(1) per file. `editor_save_scene`
is **not automatic** — save after mutation batches before switching scenes or
starting a playtest; saving flushes pending changes (no refresh-before-save
needed).

**`input_simulate`.** Send a single event or an `events` array — **prefer one
call with multiple events**. Keep `delay_after_ms` to 100-300ms; > 500ms is
dangerous (the live game world advances during the wait). `click_node`
(`node_path`, no coordinate guessing) and `send_text` (types into the focused /
`node_path` field, firing real signals) exist. Coordinate modes: `position`
(viewport/UI) vs `world_position` (game-world, camera-aware). Full event-type
table in `references/input-events.md`.

---

## 4. Tool availability

A lean startup surface is small **on purpose** — large always-loaded tool lists
degrade tool-selection accuracy in LLM contexts. Specialised tools live in
on-demand groups you activate with `discover_tools` to reach the full surface.

**Common groups — examples, not the full list:**

| Group | Contains |
|-------|----------|
| `runtime_advanced` | `runtime_get_node_state`, `runtime_set_property`, `animation_player_control` |
| `signals` | `signal_emit` (`signal_manage` / `signal_list` are on the startup surface) |
| `animation_authoring` | `animation_keyframe`, `animation_get_keys`, `animationtree_edit`, ... |
| `input_map` | `input_map_action`, `input_map_event` |
| `tilemap` | `tilemap_set_cells`, `tilemap_read_cells` |
| `audio` | `audiobus_edit`, `audiobus_list` |
| `3d_tools` | `3d_create_primitive`, `3d_create_camera`, `3d_create_light`, ... |
| `navigation` | `navigation_edit` |
| `lsp_code_analysis` | `lsp_diagnostics`, `lsp_project_diagnostics`, `lsp_hover`, `lsp_symbols` |
| `lsp_code_navigation` | `lsp_completion`, `lsp_definition`, `lsp_references` |
| `debugger` | `debug_state`, `debug_set_breakpoint`, `debug_continue`, ... |
| `editor_advanced` | `editor_refresh`, `editor_screenshot`, `editor_wait_for_idle` |
| `classdb` | `classdb_get_info`, `classdb_search` |
| `cleanup` | `file_delete`, `folder_delete`, `resource_delete`, `scene_close`, ... |

Call `discover_tools()` with no arguments to see the full catalogue.

**Version gating:** on older Godot versions, version-gated tools are hidden from
the tool list; a direct call fails with `UNSUPPORTED`, and the hint names the
required version.

**Extensions:** projects can register their own MCP tools. They appear in
`discover_tools` alongside the built-ins; `extensions_refresh` rescans after the
extension files change.

**Read-only mode.** Set `GODOT_MCP_READ_ONLY=1` in `.mcp.json` env (or use the
dock's read-only toggle, which writes the env var for you). Only tools with
`readOnlyHint: true` are visible — safe for exploration and auditing; the same
annotation-driven filter applies to built-in and extension tools. To exit, turn
it off and reconnect the client — the tool list is decided at connect time.

**Context management:** if on-demand groups accumulate and degrade tool
selection, reset them — `discover_tools({reset: true})` (all) or
`discover_tools({reset: ["tilemap", "audio"]})` (selective).

---

## 5. Headless mode

**Launch:** `godot --headless --editor --path <project>`

Build and validate normally: `script_check`, `lsp_project_diagnostics`,
`editor_get_console`, and scene/node inspection all work. Run `editor_refresh`
after external file writes (the filesystem scan is async headless).

**Playtesting is unavailable headless** — there is no display server for the
game process, so `game_start` fails with `HEADLESS_UNSUPPORTED`, and
`editor_screenshot` fails the same way. Verify via state queries and console
output instead.

---

## 6. Key constraints

**Never edit .tscn files directly.** Always use the MCP scene tools
(`scene_create`, `scene_create_node`, `node_set_property`). Direct `.tscn` edits
bypass the editor's scene tree and cause silent data loss.

**Root node path.** The root node is always path `"."` — not the node name.
Children are relative.

**Runtime state visibility.** `runtime_get_node_state` shows primarily `@export`
vars and inspector-visible fields. Use `execute_code` for internal state.

**Node method invocation.** `node_call_method` is editor-side only. For methods
on the running game use `execute_code` (its default channel is the running game):
`get_node('/root/Main/Player').call('take_damage', 25)`.

### Stale live instance after a script edit (Godot < 4.4)

On Godot **< 4.4** (4.2, 4.3), editing a `.gd` already attached to a **live**
node does **not** reach that running instance: a newly-added method fails with
`INVALID_METHOD`, and a changed method **body** runs the old code silently.
`editor_refresh`, re-`node_set_script`, and a fresh node all keep the stale code
— **relaunch the editor** (or disable+re-enable the plugin) before calling the
changed members (`script_write` and `node_call_method` flag this in their hints).
Best practice: write the full script **before** attaching it. On 4.4+ scripts
hot-reload, so this doesn't apply.

**Env var lifecycle.** `GODOT_MCP_*` env vars (e.g. `GODOT_MCP_READ_ONLY`,
`GODOT_MCP_EDITOR_PORT`) are read when the MCP server process starts. After
editing `.mcp.json`, reconnect the MCP client — the tool list is decided at
connect time, and a reconnect respawns the server with the fresh env.

**GDScript pattern — prefer load() over preload().** Use `class_name` on every
script for script-to-script references (no preload/load needed). Use `load()` for
PackedScene instantiation and resource references — it evaluates at runtime and
tolerates creation order. Never use `preload()` in generated code unless the
target already exists and there are no circular dependencies.

**GDScript pattern — use %UniqueName for node references.** Mark
frequently-referenced nodes with `unique_name: true` (via `scene_create_node`, or
by setting `unique_name_in_owner` with `node_set_property`). Reference them as
`@onready var label: Label = %ScoreLabel` — this survives reparenting. Use
`$ChildName` only for structural direct children.

**Console log sources.** `editor_get_console` buffer mode captures all output on
Godot 4.5+ (Logger API); it falls back to file-tail on 4.2-4.4 with ~200ms
latency. Use `source: "buffer"` (default) for real-time capture.

**Node groups.** Use `node_groups` to add/remove/list groups — not
`node_set_property` (groups are not a node property). Batch mode supports
multiple nodes:
`node_groups(action: "add", entries: [{node_path: ".", group: "enemies"}, ...])`.

**File path conventions.** Project files use `res://`; `user://` data goes
through the save tools (`save_read` / `save_write` / `save_delete` / `save_list`,
`user_data` group) and screenshot save paths (`user://screenshots/`). Absolute OS
paths and `..` traversal are rejected by the file guard. `scene_create` and
`script_write` auto-create parent directories; other tools may not — use
`folder_create` for non-standard paths first.

---

## 7. Error recovery

**Debug-first — when runtime behaviour is unexpected, always diagnose before
retrying:**

1. `debugger_get_log` — check what actually happened
2. Check `delay_after_ms` in `input_simulate` (>500ms lets the world advance)
3. Check game state via `execute_code` (still playing? player alive?)
4. THEN retry with adjusted parameters

This avoids misdiagnosis loops that waste thousands of tokens retrying when the
root cause is elsewhere (e.g. input delays letting enemies kill the player before
events process).

### Common error codes

| Code | Cause | Recovery |
|------|-------|----------|
| `GAME_NOT_RUNNING` | No game started, or it crashed | `game_start`, then `editor_get_console` if it fails again |
| `NOT_FOUND` | Node path, file, or `script_edit` `old_string` not found | Root is `"."`, children relative; check `scene_get_tree` |
| `NOT_UNIQUE` | `script_edit` `old_string` matched more than once | Widen the span or pass `replace_all` |
| `PARENT_NOT_FOUND` | Parent dir doesn't exist | `scene_create` / `script_write` auto-create dirs; others may not |
| `ALREADY_PLAYING` | Game already running | `game_stop` first, or use `if_running: "return"` |
| `COMPILATION_FAILED` | Script errors | `editor_refresh` then `editor_get_console` for details |
| `UNSUPPORTED` | Tool/operation needs a newer Godot | The hint names the required version |
| `LOG_UNAVAILABLE` | Log couldn't be read | On 4.5+ `source: "buffer"` works without a file; on 4.2-4.4 enable file logging (ProjectSettings -> Debug) + restart |
| `LOG_BUSY` | Log read open failed — an external process may hold it | Retry shortly; on 4.5+ use `source: "buffer"` (in-memory) |

For deeper runtime diagnosis when logs aren't enough, activate the `debugger`
group (`debug_state`, breakpoints, `debug_continue`).

---

## 8. Checkpoint pattern

For complex builds, commit progress at milestones. A standard order: project
structure + main scene → game logic scripts → input handling → win/lose
conditions → visual feedback → regular verification (`game_start` + runtime
checks) → headless verification (if applicable).

If a session ends mid-task, record the current step and state so the next session
can continue without re-reading the entire project.

---

## 9. Token efficiency

MCP tool calls are expensive — each round trip costs tokens for the request, the
response, and the context it occupies:

- **Batch properties** instead of one-at-a-time: one `node_set_property` with
  `batch` replaces 5-10 individual calls.
- **Activate groups in one call.** Pass an array to `discover_tools` — every
  activation makes the client re-process the full tool list, so batch them.
- **Use `scene_get_tree` sparingly.** `include_properties: true` returns
  hundreds of lines even on a small scene; use `node_get_property` for targeted
  reads. Paged reads (`scene_query`, `editor_get_console`, `debugger_get_log`)
  carry a `returned`/`has_more` envelope.
- **Read the console incrementally.** `editor_get_console` supports `since_id`
  (page "what's new"), `level_filter`, and `limit`; `debugger_get_log` supports
  `limit` and `text_filter`.
- **Keep `node_get_property_list` on `mask="common"`** (default; the 8-12
  most-edited properties) or use `node_get_property` — `mask="all"` is large.
- **Never screenshot for debugging logic.** `debugger_get_log` +
  `runtime_get_node_state` cost a fraction of a screenshot. Budget:
  `image_detail: "low"` for layout sanity, `"mid"` for most UI checks, `"full"`
  only to read small text; disk modes always persist full-res. Only use
  `runtime_screenshot` for visual layout, alignment, or rendering issues.
- **Partial script reads.** If you wrote the script, read only the function you
  need (`start_line`/`end_line`).
- **Reset unused tool groups.** Accumulated on-demand groups degrade tool
  selection — `discover_tools({reset: true})` clears them.
- **Diagnose before retrying.** One `debugger_get_log` that reveals the root
  cause beats blindly retrying `input_simulate` five times.
- **Use `classdb_get_info` with `sections`.** All sections on a complex class
  returns thousands of lines — ask for `["properties"]` or `["signals"]` only.
- **Use specific keys for project settings.** `project_get_settings(prefix:
  "display")` returns hundreds of settings (including defaults); use a single
  `key` for one value. For a broad survey, `Read(project.godot)` is far cheaper —
  it holds only non-default settings. If the spec states the value, skip the read
  and set it directly.
- **Follow the `hint` field** on both errors and successes instead of
  re-querying or blindly retrying — it names the recovery step or the next tool.

---

## 10. Parallel sessions

Multiple sessions on one editor are safe — a mutation queue and a scene lease
serialize conflicting work automatically; under contention responses get
**slower, not broken** (a lease steal takes ~8s). If a response mentions another
session editing a scene, do tab-independent work (scripts, files, project
settings, autoloads, console reads) first. Full guide:
`references/parallel-sessions.md`.

---

## Gotcha quick-reference

These are the most common sources of wasted tool calls and retries:

| Tool | Gotcha |
|------|--------|
| `input_simulate` | `delay_after_ms` > 500ms is dangerous — game world advances |
| `scene_create_node` | `parent_path` is the parent to create under; `node_name` names the new node |
| `node_set_property` | `batch` mode: top-level `property`/`value` ignored when `batch` present |
| `node_set_property` | Typed values need `{type: "Vector2", x: ...}` wrappers — plain `{x: 1, y: 2}` won't coerce |
| `script_edit` | `old_string` must match byte-for-byte (whitespace included); `NOT_UNIQUE` -> widen the span or `replace_all` |
| `signal_manage` vs `signal_emit` | `signal_manage` = persistent editor-time connect/disconnect; `signal_emit` = fire now (`channel: "editor"` default \| `"runtime"`) |
| `scene_create` vs `scene_create_node` | `scene_create` = new `.tscn` file (open it after); `scene_create_node` = add a node to the open scene |
| `autoload_manage` vs `project_set_setting` | Always use `autoload_manage` for autoloads; `project_set_setting` rejects them |
| `autoload_manage` + console errors | After registering, `editor_refresh` before trusting console errors — stale cache shows false "identifier not found" |
| `execute_code` | Annotated `destructiveHint: true`; expression-only; responses larger than a property read |
| `editor_refresh` | Needed after external writes; especially headless |
| `scene_delete` / `scene_close` | Console shows `_set_main_scene_state: Cannot convert argument 2 from Object to Object` when closing non-active tabs — **benign Godot engine noise** from the deferred queue, not a bug. Tabs close correctly. Don't try to fix or investigate it. |
| `game_start` | `scene_path` accepts `"main"`, `"current"`, or a `res://` path |
| `node_groups` | Only way to manage groups — `node_set_property` cannot set them |
| `classdb_get_info` | Use the `sections` param to limit output — a full dump includes hundreds of inherited properties |
| `editor_save_scene` | Not automatic — call after mutation batches before playtest or scene switch |
| `project_get_settings` | Broad `prefix` returns hundreds of lines — use a specific `key` or skip the read if the spec states the value |
