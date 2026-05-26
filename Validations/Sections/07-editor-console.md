# Section 7 — Editor Operations & Console

**Dependencies:** Section 2 (nodes in main.tscn)
**Tools tested:** editor_save_scene, editor_screenshot, editor_get_console, editor_get_errors, editor_wait_for_idle, editor_refresh, execute_code (for seeding)
**Tests:** 16

---

**7.1** `editor_save_scene`
- **Expect:** success

**7.2** `editor_screenshot`
- **Expect:** Returns inline PNG

**7.3** Set texture then screenshot node — `node_set_property` Sv2Sprite texture=`{"type":"Resource","path":"res://icon.svg"}`, then `editor_screenshot` node_path=`Sv2Sprite`
- **Expect:** PNG focused on Sv2Sprite (now has visible texture)

**7.4** `editor_get_console` — (default params)
- **Expect:** success, returns console output

**7.5** Seed console — `execute_code` code=`push_warning("SV2_SEED_Alpha42 test_line(parens)")` **[gated: skip if execute_code unavailable]**
- **Expect:** success

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

**7.16** `editor_get_errors`
- **Expect:** success (may be empty list)

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

None — no persistent artifacts.
