# Section 6 — Script Operations

**Dependencies:** Section 1 (actor.gd exists)
**Tools tested:** script_read, script_write, script_check, asset_list, asset_get_dependencies
**Tests:** 8

---

**6.1** `script_read` — file_path=`res://sv2_validation/actor.gd`
- **Expect:** Full content matching what was written in Section 1

**6.2** `script_read` (range) — file_path=`res://sv2_validation/actor.gd`, start_line=1, end_line=3
- **Expect:** First 3 lines only

**6.3** `script_check` — file_path=`res://sv2_validation/actor.gd`
- **Expect:** valid=true, 0 diagnostics

**6.4** `script_write` (with error) — file_path=`res://sv2_validation/sv2_bad_script.gd`, content=`extends Node\n\nvar x = {\n`
- **Expect:** success write, `valid: false`, `diagnostics` array non-empty

> **REGRESSION WATCH (FIX-1, T:98c02f3):** If diagnostics are missing from the
> response (only success/fail without structured error info), inline diagnostics
> have regressed.

**6.5** `script_write` (preload hint) — file_path=`res://sv2_validation/sv2_preload_test.gd`, content=`extends Node\n\nvar x = preload("res://sv2_nonexistent_file_99999.gd")\n`
- **Expect:** `valid: false`, diagnostics mention preload failure with actionable hint suggesting `load()` instead

> **REGRESSION WATCH (a46487b):** If diagnostics show only generic error without
> mentioning preload specifically, the preload hint has regressed. Previous
> off-by-one bug in LogBuffer `pre_id` caused missed hints. Flag as **Major**.

**6.6** `script_check` — file_path=`res://sv2_validation/sv2_bad_script.gd`
- **Expect:** valid=false, diagnostics with line/column info

**6.7** `asset_list` — folder_path=`res://sv2_validation/`, name_glob=`*.gd`
- **Expect:** Lists actor.gd, sv2_bad_script.gd, sv2_preload_test.gd

**6.8** `asset_get_dependencies` — file_path=`res://sv2_validation/material.tres`
- **Expect:** Dependency on shader.gdshader

---

## Console error check

Call `editor_get_console` and scan output since section start for unexpected errors.
- **FAIL** if any line contains: `UndoRedo history mismatch`, `SCRIPT ERROR`, `FATAL`, or unexpected `ERROR:` lines not caused by intentional guard tests.
- **PASS** if only expected noise (e.g., `Failed loading resource` from NOT_FOUND guard tests).
- Note: expected errors from guard tests (e.g., loading nonexistent resources) are NOT failures.

## Cleanup

- `script_delete` file_path=`res://sv2_validation/sv2_bad_script.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_preload_test.gd`
