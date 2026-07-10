# Section 6 — Script Operations

**Dependencies:** Section 1 (actor.gd exists)
**Tools tested:** script_read, script_write, script_check, asset_list, asset_get_dependencies
**Tests:** 10

---

**6.1** `script_read` — file_path=`res://sv2_validation/actor.gd`
- **Expect:** Full content matching what was written in Section 1

**6.2** `script_read` (range) — file_path=`res://sv2_validation/actor.gd`, start_line=1, end_line=3
- **Expect:** First 3 lines only. Uniform pagination contract (concern 054; ledger #20): response carries `total_lines`, `returned`=3 (this window's line count), `has_more`, and — because line 3 is before EOF — `next_start_line`=4 plus a `hint` naming `next_start_line`. Pass `next_start_line` back as `start_line` and the next window continues; loop until `has_more` is `false`.

> **REGRESSION WATCH (concern 054; ledger #20):** `script_read` and `save_read` share one
> pagination contract — `has_more` (always on success) + `total_<unit>` + `returned` +
> a resume field (`next_start_line`) + a `hint`, the last two only when `has_more`. If a range read
> lacks `has_more`/`total_lines`/`returned`, or a `has_more` window lacks `next_start_line`/`hint`,
> the contract has regressed. If a response still carries the old `truncated`, the rename has
> regressed. Flag as **Major**.

**6.2b** `script_read` (full file) — file_path=`res://sv2_validation/actor.gd` (no range)
- **Expect:** Full content. Contract fields present: `has_more`=false, `total_lines`, and `returned` = the full line count (a full read that fits the cap has `has_more:false`, and carries NO `next_start_line`/`hint`).

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
- **Expect:** valid=false, diagnostics=[1 entry], severity="error". **On Godot 4.5+:** the error entry carries a `line` key with the REAL parse-error line (recovered from the 4.5+ Logger capture of the in-process reload). **On Godot 4.2–4.4:** the `line` key is OMITTED entirely (no structured line from the file-tail capture — never a fabricated `0`). **`col`/`column` is NEVER emitted** on any version (columns are `lsp_diagnostics`' domain — use that tool for precise error location). Hint-severity entries (e.g. the preload hint in 6.5) never carry `line` either — hints are about an identifier, not a source position.

> **REGRESSION WATCH (S6.6, 41n-undecies T4):** Prior behavior hardcoded
> `"line": 0` on every diagnostic regardless of version — a fabricated value, not
> a real one. If a 4.5+ run's error diagnostic lacks `line`, or a <4.5 run's error
> diagnostic carries a `line` key (fabricated or otherwise), or any diagnostic
> ever carries `col`/`column`, the real-line emission has regressed. Flag as
> **Major**.

**6.7** `asset_list` — path_prefix=`res://sv2_validation/`, name_glob=`*.gd`
- **Expect:** Lists actor.gd, sv2_bad_script.gd, sv2_preload_test.gd. Envelope (ledger #20): `returned` (was `count`) = entries this page, `total_assets` = full count, `has_more` (was `truncated`) — cursor-less (navigate by `path_prefix`+filters, no `next_offset`).
- **Note:** the filter param is `path_prefix`, not `folder_path`.

**6.8** `asset_get_dependencies` — file_path=`res://sv2_validation/material.tres`
- **Expect:** Dependency on shader.gdshader. Envelope (ledger #20): `returned` (was `count`), `total_dependencies`, `has_more` (was `truncated`) — cursor-less.

**6.9** `asset_list` over-max `limit` clamp — path_prefix=`res://`, limit=`5000`
- **Expect (ledger #20, D8 — flagged behavior change):** success (NOT INVALID_PARAMS). The over-max `limit` (>2000) now **clamps** to the 2000 max and discloses `limit_clamped`=true, with a clamp clause in the `hint`. A `limit` ≤ 0 still **rejects** (INVALID_PARAMS) — validation is uniform (over-max → clamp; ≤0/non-int → reject).

> **REGRESSION WATCH (ledger #20, D8):** `asset_list`'s over-max `limit` (>2000) previously
> returned INVALID_PARAMS; it now clamps + discloses `limit_clamped`. If an over-max `limit`
> errors instead of clamping, the D8 behavior change has regressed. A `limit`=0 must still
> reject. Flag as **Major**.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `script_delete` file_path=`res://sv2_validation/sv2_bad_script.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_preload_test.gd`
