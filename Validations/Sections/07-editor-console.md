# Section 7 — Editor Operations & Console

**Dependencies:** Section 2 (nodes in Sv2Main.tscn)
**Tools tested:** editor_save_scene, editor_screenshot, editor_get_console, editor_wait_for_idle, editor_refresh, execute_code (for seeding)
**Tests:** 15

---

**7.1** `editor_save_scene`
- **Expect:** success

**7.2** `editor_screenshot`
- **Expect:** Returns inline PNG

**7.3** Set texture then screenshot node — `node_set_property` Sv2Sprite texture=`{"type":"Resource","path":"res://icon.svg"}`, then `editor_screenshot` node_path=`Sv2Sprite`
- **Expect:** PNG focused on Sv2Sprite (now has visible texture)

**7.4** `editor_get_console` — (default params)
- **Expect:** success, returns console output

**7.5** Seed console — `execute_code` code=`push_warning("SV2_SEED_Alpha42 test_line(parens)")`, context=`"editor"`
- **Expect:** success — `context:"editor"` runs the snippet in the editor process (no running game needed), so the warning lands in the editor console for 7.6+ to read. Without `context:"editor"`, `execute_code` defaults to `context:"game"` and returns `GAME_NOT_RUNNING` when no game is running.

**7.6** `editor_get_console` — text_filter=`SV2_SEED`, is_regex=`false`
- **Expect:** count >= 1

**7.7** `editor_get_console` — text_filter=`SV2_SEED_Alpha\\d+`, is_regex=`true`
- **Expect:** count >= 1

> **REGRESSION WATCH (a828cb1):** If `\\d+` (double-escaped in JSON) matches but
> the tool does NOT warn about potential double-escaping, the double-escape
> metacharacter warning has regressed. Check response hints for escaping note.

**7.8** `editor_get_console` — text_filter=`test_line(parens)`, is_regex=`false`
- **Expect:** count >= 1 ��� metacharacters treated as literal in plain mode

**7.9** `editor_get_console` — text_filter=`(unclosed`, is_regex=`true`
- **Expect:** INVALID_PARAMS with regex hint

**7.10** `editor_get_console` — text_filter=`SV2_SEED`, level_filter=`["warning"]`
- **Expect:** count >= 1, both filters compose (AND)

**7.11** `editor_get_console` — clear_buffer=`true`
- **Expect:** success, buffer cleared

> **REGRESSION WATCH (FIX-8, T:98c02f3):** If `clear_buffer` param is rejected,
> the buffer-clear feature has regressed. Flag as **Major**.

**7.12** `editor_get_console` — text_filter=`SV2_SEED`
- **Expect:** count=0 (buffer was cleared in 7.11)

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
