# Section 7 — Editor Operations & Console

**Dependencies:** Section 2 (nodes in Sv2Main.tscn)
**Tools tested:** editor_save_scene, editor_screenshot, editor_get_console, editor_wait_for_idle, editor_refresh, execute_code (for seeding)
**Tests:** 22

> **Precondition — `editor_screenshot` self-diagnoses a collapsed viewport.**
> The tool no longer returns a blank `2x2` / ~81-byte PNG for a viewport that
> cannot composite. A **wrong main screen** (Script / AssetLib / Output active,
> not minimized) is **auto-healed** — the tool switches to a 2D/3D main screen,
> re-captures, and discloses via a success-side `remediation:["switched_main_screen"]`
> field (the switch is one-way; the editor is left on 2D/3D — expected, not a
> failure). A **minimized** editor cannot composite at all, so it returns the
> `EDITOR_VIEWPORT_UNAVAILABLE` error (**not** a 2x2 PNG, **not** headless — a
> headless editor returns `HEADLESS_UNSUPPORTED`, so any PNG rules headless out);
> pass `force_foreground_editor:true` to have the tool un-minimize + raise the
> window and capture. For 7.2 (baseline) the editor should already be restored on
> a 2D/3D screen so no remediation is needed.

---

**7.1** `editor_save_scene`
- **Expect:** success

**7.2** `editor_screenshot` — editor restored + foregrounded on the **2D** main screen
- **Expect:** Returns inline PNG at real viewport dimensions (hundreds of px, KB-scale bytes), and **no** `remediation` field (nothing had to be healed). A `2x2` / ~81-byte result on a genuinely-2D-foregrounded editor is a regression — flag it.

**7.2b** Auto-heal (standard path) — switch to the **Script** main-screen tab, then `editor_screenshot`
- **Expect:** A healed **usable** frame (real dimensions) plus `remediation:["switched_main_screen"]`. The editor is left on the 2D screen afterward (no restore) — expected. A blank/2x2 frame or a missing `remediation` is a FAIL.

**7.2c** Auto-heal (node-focused path) — on the Script tab, `editor_screenshot` node_path=`Sv2Sprite` (a Node2D), then (separately) node_path of any **Node3D** in the scene
- **Expect:** Each returns a healed usable frame with `remediation` including `switched_main_screen` — the Node3D routes to the 3D viewport, the Node2D to the 2D viewport. First set the sprite texture if needed: `node_set_property` Sv2Sprite texture=`{"type":"Resource","path":"res://icon.svg"}`.

**7.2d** Minimized signal — **minimize** the editor window, then `editor_screenshot`
- **Expect:** `EDITOR_VIEWPORT_UNAVAILABLE` (**not** a 2x2 PNG, **not** `HEADLESS_UNSUPPORTED`). The `hint` names the minimized cause and points to `force_foreground_editor` / `script_check`.
> **REGRESSION WATCH (41o-duodecies):** a minimized editor must return `EDITOR_VIEWPORT_UNAVAILABLE`, never a tiny/blank PNG and never `HEADLESS_UNSUPPORTED`. If it returns an image or hangs to a 30 s TIMEOUT, the upfront `window_get_mode` guard regressed.

**7.2e** Foreground lever — while the editor is still minimized, `editor_screenshot` force_foreground_editor=`true`
- **Expect:** The editor un-minimizes and a **usable** frame returns, with `remediation` including `foregrounded_editor` (and `switched_main_screen` too if it was also on a non-2D/3D screen).

**7.2f** Cause-C freshness — put the editor **unfocused behind the terminal** (visible, not minimized), then `editor_screenshot`
- **Expect:** A **fresh full-size** frame — not stale, not collapsed. The editor viewport is a SubViewport that renders regardless of OS focus, so an unfocused-but-visible editor is not a failure.

**7.2g** Disk mode (standard capture) — with the editor restored on a 2D/3D screen, `editor_screenshot` image_response_mode=`disk`
- **Expect:** A **lean** response — `path`, `width`, `height`, `bytes`, `mime_type` and **NO** `image_base64`. `path` is an absolute file path ending `.png` (auto-named under `user://screenshots/`); the file exists on disk. Cleanup: delete the written PNG.

**7.2h** Both mode — `editor_screenshot` image_response_mode=`both`, save_path=`res://sv2_shot.png`
- **Expect:** The inline shape (`image_base64`, `mime_type`, `width`, `height`, `bytes`) **plus** `path` = the globalized absolute path of the saved `res://sv2_shot.png`; the file exists. Cleanup: `file_delete` (or `resource_delete`) `res://sv2_shot.png`.

**7.2i** Oversize escape hatch — create a `Node3D` (`scene_create_node` node_type=`Node3D`, node_name=`Sv2ShotProbe3D`, parent_path=`.`), then `editor_screenshot` node_path=`Sv2ShotProbe3D` at default size (no size params)
- **Expect:** `RESPONSE_TOO_LARGE` whose `hint` names `image_response_mode:"disk"` as the fix (a full-size 3D capture exceeds the WS buffer). Then re-call `editor_screenshot` node_path=`Sv2ShotProbe3D` image_response_mode=`disk` → lean envelope + `path` on disk (no `image_base64`). Cleanup: `scene_delete_node` `Sv2ShotProbe3D`; delete the written PNG.
> **REGRESSION WATCH (41o-duodecies-ter):** the oversize inline hint must name `image_response_mode:"disk"` (the tailored escape hatch), not the old generic "narrow the query / paginate" boilerplate. If the disk retry still returns `image_base64` or omits `path`, the disk-mode lean envelope regressed. Flag as **Major**.

**7.4** `editor_get_console` — (default params)
- **Expect:** success, returns console output

**7.5** Seed console — `execute_code` code=`push_warning("SV2_SEED_Alpha42 test_line(parens)")`, context=`"editor"`
- **Expect:** success — `context:"editor"` runs the snippet in the editor process (no running game needed), so the warning lands in the editor console for 7.6+ to read. Without `context:"editor"`, `execute_code` defaults to `context:"game"` and returns `GAME_NOT_RUNNING` when no game is running.

**7.6** `editor_get_console` — text_filter=`SV2_SEED`, is_regex=`false`
- **Expect:** `returned` >= 1 (ledger #20: the matching-line count field is `returned`, was `count`)

**7.7** `editor_get_console` — text_filter=`SV2_SEED_Alpha\\d+`, is_regex=`true`
- **Expect:** `returned` >= 1

> **REGRESSION WATCH (a828cb1):** If `\\d+` (double-escaped in JSON) matches but
> the tool does NOT warn about potential double-escaping, the double-escape
> metacharacter warning has regressed. Check response hints for escaping note.

**7.8** `editor_get_console` — text_filter=`test_line(parens)`, is_regex=`false`
- **Expect:** `returned` >= 1 — metacharacters treated as literal in plain mode

**7.9** `editor_get_console` — text_filter=`(unclosed`, is_regex=`true`
- **Expect:** INVALID_PARAMS with regex hint

**7.10** `editor_get_console` — text_filter=`SV2_SEED`, level_filter=`["warning"]`
- **Expect:** `returned` >= 1, both filters compose (AND)

**7.11** `editor_get_console` — clear_buffer=`true`
- **Expect:** success, buffer cleared

> **REGRESSION WATCH (FIX-8, T:98c02f3):** If `clear_buffer` param is rejected,
> the buffer-clear feature has regressed. Flag as **Major**.

**7.12** `editor_get_console` — text_filter=`SV2_SEED`
- **Expect:** `returned`=0 (buffer was cleared in 7.11)

**7.13** `editor_wait_for_idle`
- **Expect:** success

**7.14** `editor_refresh` — (no params, full mode)
- **Expect:** success, mode=`"full"`

**7.15** `editor_refresh` — file_paths=[`res://sv2_validation/actor.gd`]
- **Expect:** success, mode=`"targeted"`, file_count=1

---

## Version-gated `LOG_BUSY` / `LOG_UNAVAILABLE` hints (`source="file"`)

> **REGRESSION WATCH (41n-undecies-bis-bis):** `editor_get_console` with
> `source="file"` (and the shared `debugger.get_log` readers) attach a
> **version-gated** recovery hint via `MCPToolkitError.log_busy_hint` /
> `log_unavailable_hint` — not the old unconditional `DEFAULT_HINTS` string:
> - **Godot 4.5+** — the hint steers to `source="buffer"` (in-memory Logger API,
>   file-independent).
> - **Godot 4.2–4.4** — the hint does **NOT** mention `source="buffer"` (the buffer
>   tails the *same* log file, so it can't be a fallback); it gives retry (`LOG_BUSY`)
>   / enable-file-logging (`LOG_UNAVAILABLE`) guidance only.
>
> If a `source="buffer"` steer appears on a 4.2–4.4 editor, the version gate has
> regressed — flag as **Major**.

**`LOG_BUSY` is not deterministically triggerable from the sweep.** Per the Phase 0
engine model, the logger holds `godot.log` **deny-nothing**, so our own read open
always succeeds — there is no engine/self lock to exercise. A real `LOG_BUSY` needs an
**external read-denying holder** (antivirus scan, file-sync, backup tool) the sweep
can't provision. The deterministic truth-table (POSIX never `LOG_BUSY`; 4.5+ never
engine-`LOG_BUSY`; genuine absence → `LOG_UNAVAILABLE`; 4.4 self-held `--log-file` →
entries) is owned by **server smoke §14** (`14_asset_discovery_and_console.ts`). To
eyeball the `LOG_UNAVAILABLE` gate here, disable file logging (ProjectSettings → Debug →
File Logging), then `editor_get_console` `source="file"` → expect `LOG_UNAVAILABLE` with
the version-appropriate hint.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

None — no persistent artifacts.
