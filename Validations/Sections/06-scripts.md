# Section 6 — Script Operations

**Dependencies:** Section 1 (actor.gd exists)
**Tools tested:** script_read, script_write, script_edit, script_check, asset_list, asset_get_dependencies
**Tests:** 25

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

**6.3b** `script_check` on the one-line `class_name` form — first `script_write` file_path=`res://sv2_validation/sv2_one_line.gd`, content=`class_name Sv2OneLine extends Node\n\n\nfunc attach_child() -> void:\n\tadd_child(Node.new())\n`; then `script_check` file_path=`res://sv2_validation/sv2_one_line.gd`
- **Expect (every version):** the `script_write` response and the `script_check` response both valid=true, 0 diagnostics. The check renames only the `class_name` identifier, so the script keeps its `Node` base and `add_child` resolves.

> **REGRESSION WATCH (toolkit #16):** an error in either response means the check
> dropped the same-line `extends` again. Flag as **Major**.

**6.3c** `script_check` on a singleton that types `self` as its own class and has a factory — first `script_write` file_path=`res://sv2_validation/sv2_singleton.gd`, content=`class_name Sv2Singleton\nextends Node\n\nstatic var instance: Sv2Singleton\n\n\nstatic func create() -> Sv2Singleton:\n\treturn Sv2Singleton.new()\n\n\nfunc _enter_tree() -> void:\n\tinstance = self\n`; then `script_check` file_path=`res://sv2_validation/sv2_singleton.gd`
- **Expect (every version):** the `script_write` response and the `script_check` response both valid=true, 0 diagnostics. `editor_get_console` shows no error naming `Sv2Singleton`. The editor's Output panel (not the console) may show two error lines per check naming the class with a probe suffix: a documented limitation.
- **Restore:** the file is deleted in Cleanup.

> **REGRESSION WATCH (toolkit #16):** valid=false here means the check judged `self`
> against the registered copy of the class (the static `instance = self`) or failed on
> the `Sv2Singleton.new()` factory. A console error that names the class with a suffix
> means the console readers stopped mapping the probe's name back. Flag as **Major**.

**6.3d** `script_write` a `class_name` that clashes with the dogfood project's autoload — file_path=`res://sv2_validation/sv2_autoload_clash.gd`, content=`# Clash fixture.\nclass_name MCPRuntimeServer\nextends Node\n`; then `script_check` file_path=`res://sv2_validation/sv2_autoload_clash.gd`
- **Expect (every version):** both responses valid=false, and `diagnostics[0]` = `{severity: "error", message: "Class \"MCPRuntimeServer\" hides an autoload singleton.", line: 2}`. The editor's own scan may log the same parse error to the console; that entry is expected.
- **Restore:** delete the file at once (`script_delete`, listed in Cleanup too), so the clashing class does not stay registered.

> **REGRESSION WATCH (toolkit #16):** valid=true means the check skipped the engine's
> class-name checks again; a missing `line`, or a line other than 2, means the clash is
> no longer reported on its declaration. Flag as **Major**.

**6.3e** `script_check` on scripts in the project's script-templates folder (default settings: `res://script_templates`) — first `script_write` file_path=`res://script_templates/Node/fine_template.gd`, content=`extends Node\n\n\nfunc fine() -> int:\n\treturn 1\n`; then `script_write` file_path=`res://script_templates/Node/broken_template.gd`, content=`extends Node\n\n\nfunc broken() -> int:\n\treturn "text"\n`; then `script_check` on each; then `script_write` file_path=`res://script_templates_v2/x.gd` with the broken content, and `script_check` on it
- **Expect (every version):** the fine template's write and check valid=true, 0 diagnostics. The broken template's `script_write` response valid=false, and its `script_check` valid=false with an error diagnostic for the `return "text"` type mismatch. The same for `res://script_templates_v2/x.gd`: a folder whose name starts with the templates folder's counts as that folder. `script_write` and `script_check` print the compile's errors under `gdscript://…`; those console entries are expected.
- **Restore:** at once, `folder_delete` path=`res://script_templates`, recursive=true, if the case created it (the first `script_write` response carries `dirs_created: true`), and `folder_delete` path=`res://script_templates_v2`, recursive=true (listed in Cleanup too), so the dogfood project keeps no script templates of the case's.

> **REGRESSION WATCH (toolkit #114):** valid=true on a broken file means the check's copy
> took a path in the templates folder again, where the editor loads a script without
> parsing it. Flag as **Major**.

**6.3f** `script_check` on a relative `preload()` — first `script_write` file_path=`res://sv2_validation/sv2_rel_dep.gd`, content=`extends RefCounted\n\n\nfunc value() -> int:\n\treturn 1\n`; then `script_write` file_path=`res://sv2_validation/sv2_rel_user.gd`, content=`extends Node\n\nconst Dep := preload("./sv2_rel_dep.gd")\n\n\nfunc read() -> int:\n\treturn Dep.new().value()\n`; then `script_check` file_path=`res://sv2_validation/sv2_rel_user.gd`; then `script_write` the same file with `return "text"` in place of `return Dep.new().value()`, and `editor_get_console` level_filter=`["error"]`
- **Expect (every version):** the first write and the check valid=true, 0 diagnostics: the relative path resolves beside the file. The broken write valid=false, and on 4.5+ its console error names `res://sv2_validation/sv2_rel_user.gd`, never `gdscript://` (4.2–4.4's console holds no editor parse error).

**6.3g** `script_check` under `res://addons/` with a warning raised to an error — first `project_set_setting` `debug/gdscript/warnings/untyped_declaration` = `2` (Error), keeping the addons folder's default warning exemption (`debug/gdscript/warnings/exclude_addons` = true on 4.2–4.5; the `res://addons` entry of `debug/gdscript/warnings/directory_rules` on 4.6+); then `script_write` file_path=`res://addons/sv2_probe/sv2_untyped.gd`, content=`extends Node\n\nvar count = 1\n`; then `script_check` on it
- **Expect (every version):** the write and the check valid=true, 0 diagnostics: the addons folder is exempt from the project's warnings, and the check's copy sits in it.
- **Restore:** at once, `project_set_setting` `debug/gdscript/warnings/untyped_declaration` back to its prior value, and `folder_delete` path=`res://addons/sv2_probe`, recursive=true.

> **REGRESSION WATCH (toolkit #98):** valid=false on 6.3f's first check or on 6.3g, or a
> 6.3f error under `gdscript://`, means the check's copy compiles away from the file
> again. Flag as **Major**.

**6.4** `script_write` (with error) — file_path=`res://sv2_validation/sv2_bad_script.gd`, content=`extends Node\n\nvar x = {\n`
- **Expect:** success write, `valid: false`, `diagnostics` array non-empty

> **REGRESSION WATCH (FIX-1, T:98c02f3):** If diagnostics are missing from the
> response (only success/fail without structured error info), inline diagnostics
> have regressed.

**6.5** `script_write` (preload hint) — file_path=`res://sv2_validation/sv2_preload_test.gd`, content=`extends Node\n\nvar x = preload("res://sv2_nonexistent_file_99999.gd")\n`
- **Expect:** `valid: false`. **On Godot 4.5+:** the diagnostics mention the preload failure with an actionable hint suggesting `load()` instead. **On Godot 4.2–4.4:** `valid: false` still holds, but the `load()` hint is ABSENT, which is not a regression: the hint is built from the log buffer's errors, and before 4.5 that buffer tails the running game's log file only, so it holds no editor-side error.

> **REGRESSION WATCH (a46487b):** If diagnostics on Godot 4.5+ show only generic error without
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
- **Note:** the filter param is `path_prefix`, not `path`.

**6.8** `asset_get_dependencies` — file_path=`res://sv2_validation/material.tres`
- **Expect:** Dependency on shader.gdshader. Envelope (ledger #20): `returned` (was `count`), `total_dependencies`, `has_more` (was `truncated`) — cursor-less.

**6.9** `asset_list` over-max `limit` clamp — path_prefix=`res://`, limit=`5000`
- **Expect (ledger #20, D8 — flagged behavior change):** success (NOT INVALID_PARAMS). The over-max `limit` (>2000) now **clamps** to the 2000 max and discloses `limit_clamped`=true, with a clamp clause in the `hint`. A `limit` ≤ 0 still **rejects** (INVALID_PARAMS) — validation is uniform (over-max → clamp; ≤0/non-int → reject).

> **REGRESSION WATCH (ledger #20, D8):** `asset_list`'s over-max `limit` (>2000) previously
> returned INVALID_PARAMS; it now clamps + discloses `limit_clamped`. If an over-max `limit`
> errors instead of clamping, the D8 behavior change has regressed. A `limit`=0 must still
> reject. Flag as **Major**.

---

## script_edit — surgical span replacement

> `script_edit` is the MCP analogue of the native Edit tool: it replaces an exact
> `old_string` span in an existing script with `new_string`, routing through the
> same write/undo/index/diagnose pipeline as `script_write` (so an edit keeps the
> UndoRedo entry, reindex, and inline `.gd` diagnostics) and adds a `replacements`
> count. Set-up writes a dedicated fixture so these cases don't disturb `actor.gd`.

**6.10** `script_write` (edit fixture) — file_path=`res://sv2_validation/sv2_edit_target.gd`, content=`extends Node\n\nfunc _ready() -> void:\n\tprint("alpha")\n`
- **Expect:** success write, `valid: true`. Seeds the file the following edits mutate.

**6.11** `script_edit` (happy path — single unique match) — file_path=`res://sv2_validation/sv2_edit_target.gd`, old_string=`print("alpha")`, new_string=`print("beta")`
- **Expect:** success, `replacements`=1, plus the `script_write` envelope fields (`bytes`, `undoable`=true, `indexed`, and for a `.gd` file `valid`=true + `diagnostics`). A follow-up `script_read` shows the body now prints `"beta"` and every other byte is unchanged.

**6.12** `script_edit` (old_string not found) — file_path=`res://sv2_validation/sv2_edit_target.gd`, old_string=`print("never_present")`, new_string=`x`
- **Expect:** `NOT_FOUND` with a hint telling the agent to re-read the file and match `old_string` byte-for-byte (whitespace/indent exact). The file is untouched.

**6.13** `script_edit` (ambiguous — multiple matches, no replace_all) — first `script_edit` the fixture to `extends Node\n# mark\nvar a := 1\n# mark\nvar b := 2\n` (a whole-file-shaped surgical replace of the beta body), then old_string=`# mark`, new_string=`# done`
- **Expect:** `NOT_UNIQUE`, message reports the match count (2), hint offers "add surrounding context, or set replace_all:true". The file is untouched.
- **Note:** to reshape the fixture for this case, replace the single unique body line (e.g. old_string=`func _ready() -> void:\n\tprint("beta")`, new_string=`# mark\nvar a := 1\n# mark\nvar b := 2`).

**6.14** `script_edit` (replace_all — every occurrence) — file_path=`res://sv2_validation/sv2_edit_target.gd`, old_string=`# mark`, new_string=`# done`, replace_all=`true`
- **Expect:** success, `replacements`=2. A `script_read` confirms BOTH `# mark` lines became `# done` and the surrounding newlines are intact (no adjacent-newline collapse — the two lines stay on their own lines).

**6.15** `script_edit` (empty new_string deletes the span) — file_path=`res://sv2_validation/sv2_edit_target.gd`, old_string=`\nvar b := 2`, new_string=`` (empty)
- **Expect:** success, `replacements`=1; the `var b := 2` line (and its leading newline) is removed. Empty `new_string` is a valid delete, NOT an INVALID_PARAMS.

**6.16** `script_edit` guards (no-op + empty old_string) — two calls on `res://sv2_validation/sv2_edit_target.gd`:
- (a) old_string=`# done`, new_string=`# done` (identical) → **Expect** `INVALID_PARAMS` ("would change nothing"); no-op rejected before the file is touched.
- (b) old_string=`` (empty), new_string=`x` → **Expect** `INVALID_PARAMS` (empty `old_string` is malformed).

**6.17** `script_edit` (edits array — several edits in one call) — file_path=`res://sv2_validation/sv2_edit_target.gd`, edits=`[{"old_string": "# done\nvar a := 1", "new_string": "# done\nvar a := 2"}, {"old_string": "var a := 2", "new_string": "var second_edit := 2"}]` (no top-level `old_string` / `new_string`)
- **Expect:** success, `replacements`=2, one set of `diagnostics`. A `script_read` shows `var second_edit := 2`: the second edit matched the text the first one left.

**6.18** `script_edit` (edits array — one edit unmatched) — file_path=`res://sv2_validation/sv2_edit_target.gd`, edits=`[{"old_string": "var second_edit := 2", "new_string": "var c := 3"}, {"old_string": "never_present", "new_string": "x"}]`
- **Expect:** `NOT_FOUND`, message starts `edits[1]: `. A `script_read` still shows `var second_edit := 2`: the first edit was not written either.

> **REGRESSION WATCH (script_edit):** `script_edit` must NOT be lossy vs `script_write` —
> a successful edit carries `undoable`=true (UndoRedo entry), `indexed` (reindex), and for
> a `.gd` file inline `diagnostics`. If a successful edit lacks any of those, the shared
> pipeline reuse has regressed. If `replace_all` collapses adjacent newlines, or a no-op /
> empty-`old_string` edit is accepted instead of `INVALID_PARAMS`, or an absent span returns
> anything but `NOT_FOUND`, or an ambiguous span without `replace_all` returns anything but
> `NOT_UNIQUE`, or a failing edit in an `edits` array leaves the other edits written, flag as
> **Major**.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `script_delete` file_path=`res://sv2_validation/sv2_bad_script.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_preload_test.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_one_line.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_singleton.gd`
- `script_delete` file_path=`res://sv2_validation/sv2_autoload_clash.gd` (if 6.3d's restore did not already)
- `folder_delete` path=`res://script_templates`, recursive=true (only if 6.3e created it), and `folder_delete` path=`res://script_templates_v2`, recursive=true (if 6.3e's restore did not already)
- `script_delete` file_path=`res://sv2_validation/sv2_rel_user.gd` and `res://sv2_validation/sv2_rel_dep.gd`
- `folder_delete` path=`res://addons/sv2_probe`, recursive=true (if 6.3g's restore did not already)
- `script_delete` file_path=`res://sv2_validation/sv2_edit_target.gd`
