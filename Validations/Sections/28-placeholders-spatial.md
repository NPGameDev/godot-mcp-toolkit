# Section 28 — scene_spatial_map + placeholder generators

**Dependencies:** Section 2 (Sv2Main.tscn open)
**Tools tested:** scene_spatial_map (eager), texture_generate + sound_generate (`placeholders` group — on-demand)
**Tests:** 22

> **Group load:** `texture_generate` and `sound_generate` live in the on-demand
> `placeholders` group. Before 28.8, call `discover_tools` with query
> `"placeholder texture sound"` and confirm both tools register.
>
> **`scene_spatial_map` is EAGER** — it is in the base `tools/list`, NOT in any
> group and NOT returned by `discover_tools`. Do **not** hunt for a "spatial"
> group; it doesn't exist by design. If `scene_spatial_map` is missing from your
> available tools, your session's tool index predates the tool (the known Claude
> Code `tools/list_changed` staleness issue — see plan-repo memory
> `project_claude_p_tools_list_changed`). **Fix: fully restart the Claude Code
> session** so it re-fetches `tools/list`; the tool will then be present. (The
> server build is current if `discover_tools` shows the `placeholders` group.)
>
> All generated assets land under `res://sv2_validation/placeholders/` and are
> removed in Cleanup.
>
> **Error contract (enum guards) — 41m-sexies / ADR is server COMPATIBILITY.md.**
> This sweep runs through the **MCP server** (agent path), so an invalid **enum**
> value (`detail`, `shape`, `waveform`) is rejected by server-side Zod as
> **JSON-RPC `-32602`** with the bad param named — it never reaches the plugin.
> **Non-enum** guards (wrong array length, transparent result, wrong extension,
> path traversal) reach the plugin and return the toolkit codes
> (`INVALID_PARAMS` / `INVALID_PATH` / `PATH_DENIED`). Both are correct; the
> plugin's own enum check is defense-in-depth for the direct-dispatch (`sv2_`)
> path only.

---

## scene_spatial_map (2D)

**28.1** Build three overlapping/disjoint sprites (Sprite2D + the project icon
gives each a real ~128px texture rect; Node2D `position` is reliable, unlike
fresh-Control sizing — and Vector2 values use the typed form
`{"type":"Vector2","x":…,"y":…}`, NOT a bare `[x,y]` array):
- `scene_create_node` class_name=`Sprite2D`, node_name=`Sv2SpatA`, parent_path=`.`
- `node_set_property` `Sv2SpatA`.texture = `{"type":"Resource","path":"res://icon.svg"}`; `.position` = `{"type":"Vector2","x":0,"y":0}`
- Repeat for `Sv2SpatB` at position `{"type":"Vector2","x":20,"y":0}` (overlaps A)
- Repeat for `Sv2SpatC` at position `{"type":"Vector2","x":500,"y":500}` (disjoint)
- **Expect:** all succeed

**28.2** `scene_spatial_map` detail=`full`, class=`Sprite2D`
- **Expect:** success; `Sv2SpatA` node has `space:"2d"`, a `bounds` (Rect2 position+size, non-zero), `overlaps` includes `./Sv2SpatB` but NOT `./Sv2SpatC`, and a `nearest` pointing at `./Sv2SpatB`.

**28.3** `scene_spatial_map` detail=`brief`, class=`Sprite2D`
- **Expect:** success; nodes carry position/size only — NO `overlaps`/`bounds` keys.

**28.4** `scene_spatial_map` class=`Sprite2D`, region=`[-100,-100,300,300]`
- **Expect:** success; `./Sv2SpatA` present, `./Sv2SpatC` absent (outside region).

**28.5** `scene_spatial_map` class=`Sprite2D`, radius=`150`, center=`[0,0]`
- **Expect:** success; `./Sv2SpatC` absent (beyond radius).

**28.6** `scene_spatial_map` class=`Sprite2D`, max_nodes=`1`
- **Expect:** success; `returned:1`, `has_more:true` (ledger #20: was `truncated`), `total_nodes` = full match count, plus a hint to narrow/raise the cap. If a response still carries `truncated`, the rename has regressed.

**28.7** `scene_spatial_map` guards (dual error contract — see the intro note):
- detail=`verbose` → **JSON-RPC -32602** naming `detail` (enum rejected server-side by Zod)
- region=`[1,2,3]` (wrong length) → **INVALID_PARAMS** mentioning `region` (non-enum guard, reaches the plugin)

## scene_spatial_map (3D)

**28.7b** 3D bounds:
- `scene_create_node` class_name=`MeshInstance3D`, node_name=`Sv2SpatMesh`, parent_path=`.`
- `node_set_property` `Sv2SpatMesh`.position = `{"type":"Vector3","x":1,"y":2,"z":3}` (a mesh is optional — a mesh-less MeshInstance3D yields a zero-size AABB at its origin)
- `scene_spatial_map` subtree=`Sv2SpatMesh`
- **Expect:** success; the node reports `space:"3d"` with `bounds`/`size` of length 3 (AABB).

## texture_generate (placeholders group)

**28.8** `discover_tools` query=`"placeholder texture sprite sound"`
- **Expect:** `texture_generate` and `sound_generate` register, and the
  dominant-match filter activates **only** `placeholders` — NOT `asset_ops` or
  `path_editing` (Item C, 41m-sexies). The incidental `texture`/`sprite`/`sound`
  substring matches are pruned because `placeholders` dominates the score.

**28.9** Every shape — for each of `solid`, `circle`, `triangle`, `diamond`, `arrow`, `checkerboard`, `grid`:
- `texture_generate` file_path=`res://sv2_validation/placeholders/shape_<shape>.png`, shape=`<shape>`, width=`32`, height=`32`, fill_color=`"#3366ff"`, outline_color=`"#000000"`, if_exists=`replace`
- **Expect:** success; `class` is **`Texture2D`** — always populated (Item B derives it by construction), **no** "did not index within 5000ms" warning, and `elapsed_ms` ≈ 0; `status:"created"`.

**28.10** Colour formats — generate four solids with fill_color = `"#ff8800"` / `"red"` / `[0.1,0.2,0.9]` / `[255,128,0]`
- **Expect:** all succeed (hex, named, 0-1 array, 0-255 array all parse).

**28.11** Hollow shape — `texture_generate` shape=`circle`, fill_color=`[0,0,0,0]`, outline_color=`"#00ff00"`, outline_width=`3`
- **Expect:** success (transparent fill → outline-only ring).

**28.12** Label overlay — `texture_generate` shape=`solid`, fill_color=`"#444444"`, label=`"Enemy"`, label_color=`"#ffffff"`
- **Expect:** success; the PNG carries centred white text (visually confirm if possible).

**28.13** Dimension cap — `texture_generate` shape=`solid`, width=`4096`, height=`4096`
- **Expect:** success; response echoes `width<=1024`, `height<=1024` (clamped, not rejected).

**28.14** `if_exists` — write `if_exists.png` (replace), then re-call with shape=`circle`, if_exists=`return`
- **Expect:** second call `status:"returned"` (idempotent no-op). A third call with if_exists=`fail` → **ALREADY_EXISTS**.

**28.15** texture guards:
- file_path=`.../x.jpg` → **INVALID_PATH** mentioning `png`
- file_path=`res://../escape.png` → **PATH_DENIED**
- fill+outline+background all `[0,0,0,0]` → **INVALID_PARAMS** mentioning `transparent`
- shape=`hexagon` → **JSON-RPC -32602** naming `shape` (enum, server-side; the plugin's `INVALID_PARAMS` is defense-in-depth on the direct-dispatch path)

## sound_generate (placeholders group)

**28.16** Every waveform — for each of `sine`, `square`, `triangle`, `sawtooth`, `noise`:
- `sound_generate` file_path=`res://sv2_validation/placeholders/wave_<waveform>.wav`, waveform=`<waveform>`, frequency=`440`, duration=`0.1`, if_exists=`replace`
- **Expect:** success; `class` is **`AudioStreamWAV`** — always populated (Item B), **no** index warning, `elapsed_ms` ≈ 0.

**28.17** Pitch sweep + decay — `sound_generate` waveform=`square`, frequency=`200`, end_frequency=`900`, duration=`0.2`, decay=`0.1`
- **Expect:** success; response echoes `end_frequency`.

**28.18** Duration cap — `sound_generate` waveform=`sine`, duration=`30`
- **Expect:** success; response echoes `duration<=5` (clamped).

**28.19** sound guards:
- file_path=`.../x.mp3` → **INVALID_PATH** mentioning `wav`
- waveform=`fmsynth` → **JSON-RPC -32602** naming `waveform` (enum, server-side)
- file_path=`res://../escape.wav` → **PATH_DENIED**

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol. The only
expected noise: PNG/WAV reimport messages for the freshly written placeholder files.

## Cleanup

- `scene_delete_node` for `Sv2SpatA`, `Sv2SpatB`, `Sv2SpatC`, `Sv2SpatMesh`
- `folder_delete` path=`res://sv2_validation/placeholders` (recursive — removes all generated PNG/WAV)
