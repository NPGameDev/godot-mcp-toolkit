# Section 26 — LSP Tools (GDScript Language Intelligence)

**Dependencies:** Section 1 (`res://sv2_validation/` exists)
**Tools tested:** lsp_diagnostics, lsp_symbols, lsp_hover, lsp_completion, lsp_definition, lsp_references, lsp_project_diagnostics
**Groups to activate:** lsp_code_analysis, lsp_code_navigation
**Prerequisite:** Godot editor running with plugin enabled, LSP active on port 6005
**Tests:** 26 + 3 combo chains (C24, C25, C29)

---

## Setup

**26-S1.** `script_write` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, content:
```gdscript
extends Node2D

var speed: float = 100.0
var health: int = 10

signal damage_taken(amount: int)

func _ready() -> void:
	take_damage(1)

func take_damage(amount: int) -> void:
	health -= amount
	damage_taken.emit(amount)
	if health <= 0:
		queue_free()
```
- **Expect:** success

**Reference positions (0-based line/col for LSP tool input):**

| Symbol | Line | Col | Context |
|--------|------|-----|---------|
| `Node2D` | 0 | 8 | Engine class in extends |
| `speed` | 2 | 4 | Typed float variable |
| `health` | 3 | 4 | Typed int variable |
| `damage_taken` (decl) | 5 | 7 | Signal declaration |
| `_ready` | 7 | 5 | Function definition |
| `take_damage` (call) | 8 | 1 | Function call in _ready (after tab) |
| `take_damage` (def) | 10 | 5 | Function definition |
| `health` (assign) | 11 | 1 | Assignment (after tab) |
| `damage_taken` (emit) | 12 | 1 | Signal emit (after tab) |
| `health` (cmp) | 13 | 4 | Comparison in if (after tab+"if ") |

**26-S2.** `script_write` — file_path=`res://sv2_validation/sv2_lsp_bad.gd`, content:
```gdscript
extends Node2D

func _ready() -> void:
	var x = {
```
- **Expect:** success (file written; contains intentional parse error)

**26-S3.** `script_write` — file_path=`res://sv2_validation/sv2_lsp_minimal.gd`, content:
```gdscript
extends Node
```
- **Expect:** success

**26-S4.** Create shader test file. Try `script_write` first; if rejected, use `execute_code`:
```gdscript
var f = FileAccess.open("res://sv2_validation/sv2_lsp_test.gdshader", FileAccess.WRITE)
f.store_string("shader_type canvas_item;\n\nuniform float strength : hint_range(0.0, 1.0) = 0.5;\n\nvoid fragment() {\n\tCOLOR.a *= strength;\n}\n")
f.close()
return {"created": true}
```
- **Expect:** success. If both methods fail, skip shader tests (26.3, 26.10) and mark SKIP.

**26-S5.** `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_valid.gd", "res://sv2_validation/sv2_lsp_bad.gd", "res://sv2_validation/sv2_lsp_minimal.gd", "res://sv2_validation/sv2_lsp_test.gdshader"]`
- **Expect:** success. Ensures LSP indexes the new files.

**26-S6.** `discover_tools` — groups=`["lsp_code_analysis", "lsp_code_navigation"]`
- **Expect:** Both groups activated, 7 LSP tools available (`lsp_code_analysis` = 4: diagnostics/symbols/hover/project_diagnostics; `lsp_code_navigation` = 3: completion/definition/references).

---

## lsp_diagnostics (lsp_code_analysis group)

**26.1** `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`
- **Expect:** success=true, diagnostics=[], count=0

**26.2** `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_bad.gd`
- **Expect:** success=true, diagnostics non-empty, at least one entry with:
  - severity="Error"
  - line ≥ 1 and character ≥ 1 (output is 1-based)
  - message non-empty (describes the parse error)

**26.3** `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_test.gdshader`
- **Expect:** success=true, diagnostics `[]` (empty) + a `note` field — the server short-circuits `.gdshader`/`.gdshaderinc` (Godot's LSP analyzes GDScript only, so any shader "diagnostic" would be a bogus GDScript parse). Uniform across 4.2–4.7. SKIP if shader wasn't created in S4.

---

## lsp_project_diagnostics (lsp_code_analysis group)

Whole-project compile scan (server-side LSP fan-out over every project `.gd`). The 4.2+ project-wide compile signal — the "did my change break another script" check. Steered to by `script_write`/`script_check`'s compile-error hint. With `sv2_lsp_valid.gd` + `sv2_lsp_bad.gd` from Setup S1/S2 present.

**26.24** `lsp_project_diagnostics` (defaults) — no params
- **Expect:** success=true. `sv2_lsp_bad.gd` appears in `files_with_diagnostics` with an entry carrying a 1-based `line` and `severity:"Error"`. The accounting invariant holds: `scanned == clean + files_with_diagnostics.length + timed_out.length + read_failed.length` (read each integer field back over the JSON boundary via `int(...)` — a whole-dict `_eq` would float the counts). `timed_out` omitted or empty on the small dogfood scan.

> **HINT CHECK:** the success response carries a `hint` steering to the per-file
> tool for a single file and to the runtime log for runtime errors — assert the
> `hint` string mentions `lsp_diagnostics` (single-file) and `debugger_get_log`
> (runtime). Unlike server smoke §48 (which calls the handler directly and never
> sees the registry-injected hint), the sweep drives the tool through the MCP
> server, so the `successHint` IS present here — this is the layer that locks it.

**26.25** `lsp_project_diagnostics` — include_addons=`true`
- **Expect:** success=true. `scanned` (int-coerced) ≥ the 26.24 default run — addon `.gd` are now included. On the toolkit-root dogfood this pulls in `addons/godot_mcp_toolkit/**`, so the scan set (and `scanned`) grows substantially; do not assert an exact count, only the `≥` relation.

**26.26** `lsp_project_diagnostics` — `include_warnings` on a warnings-only file
1. `script_write` — file_path=`res://sv2_validation/sv2_lsp_warn.gd`, content (a lint warning, not a parse error — e.g. an unused variable / shadowed name):
   ```gdscript
   extends Node

   func _ready() -> void:
   	var unused_local := 42
   ```
2. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_warn.gd"]`
3. `lsp_project_diagnostics` — include_warnings=`false`
   - **Expect:** success=true; `sv2_lsp_warn.gd` is NOT in `files_with_diagnostics` (warnings suppressed) — it counts toward `clean`.
4. `lsp_project_diagnostics` — include_warnings=`true`
   - **Expect:** success=true; `sv2_lsp_warn.gd` now appears in `files_with_diagnostics` with a `severity:"Warning"` entry (warnings surfaced). The 26.24 invariant still holds.
5. `script_delete` — res://sv2_validation/sv2_lsp_warn.gd

> **WATCH:** the accounting invariant (`scanned == clean + files_with_diagnostics + timed_out + read_failed`) is the load-bearing contract of the fan-out — it must hold on every run regardless of `include_addons`/`include_warnings`. A drift there means a file was scanned but dropped from every bucket (a fan-out accounting bug).

---

## Guards (shared path validation)

All 6 LSP tools share `validateGdscriptPath()`. Tests below verify via two different tools to confirm the guard is shared.

**26.4** `lsp_diagnostics` — file_path=`res://sv2_validation/test.cs`
- **Expect:** success=false, code=`UNSUPPORTED_FILE_TYPE`, error mentions "C#" and ".NET"

**26.5** `lsp_diagnostics` — file_path=`res://sv2_validation/test.cpp`
- **Expect:** success=false, code=`UNSUPPORTED_FILE_TYPE`, error mentions "GDExtension"

**26.6** `lsp_diagnostics` — file_path=`C:/Users/test/script.gd`
- **Expect:** success=false, code=`INVALID_PATH`, message mentions "res://"

**26.7** `lsp_hover` — file_path=`res://sv2_validation/test.cs`, line=0, column=0
- **Expect:** success=false, code=`UNSUPPORTED_FILE_TYPE` (confirms guard is shared across tools, not just diagnostics)

---

## lsp_symbols (lsp_code_analysis group)

**26.8** `lsp_symbols` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`
- **Expect:** success=true, symbols array non-empty, each symbol has:
  - `name` (string), `kind` (human-readable label like "Function"/"Variable"), `start_line`, `end_line` (1-based)
  - Names should include: `_ready`, `take_damage`, `speed`, `health`, `damage_taken` (or a subset)
  - Token-efficient: structured names + line ranges, NOT full source code

**26.9** `lsp_symbols` — file_path=`res://sv2_validation/sv2_lsp_minimal.gd`
- **Expect:** success=true, symbols array with ≤ 2 entries (possibly empty or just implicit class)

**26.10** `lsp_symbols` — file_path=`res://sv2_validation/sv2_lsp_test.gdshader`
- **Expect:** success=true, symbols **`[]`** (empty), uniform across 4.2–4.7 — no Godot 4.x LSP serves shader `documentSymbol`. SKIP if shader not created.

---

## lsp_hover (lsp_code_analysis group)

**26.11** `lsp_hover` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=0, column=8
- **Expect:** success=true, contents non-null with Node2D class info. Verify `contents` field is wrapped in untrusted envelope (I5 — object with provenance markers, not raw string).

**26.12** `lsp_hover` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=2, column=4
- **Expect:** success=true, contents mentions "float" (type of `speed` variable)

**26.13** `lsp_hover` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=10, column=5
- **Expect:** success=true, contents includes `take_damage` function signature or type info

**26.14** `lsp_hover` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=1, column=0
- **Expect:** success=true, contents = an EMPTY I5 envelope (line 1 is empty — no symbol to hover on) — NOT a raw `null`. This is consistent with 26.11's uniform hover-wrapping (every `lsp_hover` response wraps `contents` in the untrusted I5 envelope); a raw `null` would violate that envelope contract. No error, no crash.

---

## lsp_completion (lsp_code_navigation group)

**26.15** `lsp_completion` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=8, column=1
- **Expect:** success=true, completions non-empty, each item has at least `label` (string) and `kind` (string label). count ≤ 10 (default limit from schema).

**26.16** `lsp_completion` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=8, column=1, limit=3
- **Expect:** success=true, completions array length ≤ 3, count ≤ 3

---

## lsp_definition (lsp_code_navigation group)

**26.17** `lsp_definition` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=8, column=1
- **Expect:** success=true, definition.file_path=`res://sv2_validation/sv2_lsp_valid.gd` (the `res://` contract — an in-project Windows path leaking as `file:///C%3A/...` was the `lspUri.ts` `%3A` drive-colon bug, fixed in the Pass-3 follow-up, NOT the intended form), definition.line ≈ 11 (1-based, pointing to `func take_damage` on 0-based line 10).

**26.18** `lsp_definition` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=12, column=1
- **Expect:** success=true, definition points to signal `damage_taken` declaration at ≈ line 6 (1-based, 0-based line 5). Path is `res://sv2_validation/sv2_lsp_valid.gd` (the `res://` contract; the `file:///C%3A/...` form was the now-fixed `lspUri.ts` `%3A` drive-colon bug).

**26.19** `lsp_definition` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=0, column=8
- **Expect:** success=true, definition=null OR `[]` (Node2D is an engine class with no user-file source).

---

## lsp_references (lsp_code_navigation group)

**26.20** `lsp_references` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=5, column=7
- **Expect:** success=true, references array with ≥ 2 entries for `damage_taken` (declaration + emit site). All entries have `res://` file_path (the `res://` contract — the `file:///` form was the now-fixed `lspUri.ts` `%3A` drive-colon bug) and 1-based line/column numbers.

**26.21** `lsp_references` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=3, column=4
- **Expect:** success=true, references array with ≥ 2 entries for `health` (declaration + at least one usage site). Paths are `res://` (the `res://` contract; the `file:///` form was the now-fixed `lspUri.ts` `%3A` drive-colon bug), lines are 1-based.

---

## Combo Chains

### C24. Write → diagnose → fix (end-to-end freshness)

1. `script_write` — file_path=`res://sv2_validation/sv2_lsp_c24.gd`, content (broken):
   ```gdscript
   extends Node2D

   func _ready() -> void:
   	var x = {
   ```
2. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_c24.gd"]`
3. `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_c24.gd`
   - **Expect:** diagnostics non-empty, Error severity present
4. `script_write` — same path, content (fixed):
   ```gdscript
   extends Node2D

   func _ready() -> void:
   	var x = 42
   	print(x)
   ```
5. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_c24.gd"]`
6. `lsp_diagnostics` — same path
   - **Expect:** diagnostics=[], count=0 (clean after fix)
7. `script_delete` — res://sv2_validation/sv2_lsp_c24.gd

> **WATCH (2026-05-18):** First run required full `editor_refresh()` (no file_paths)
> instead of targeted refresh at step 5 before the LSP returned clean diagnostics.
> Suspected timing edge case — `didChange` may need slightly more time to flush
> the LSP's diagnostic cache. If this recurs across runs, investigate whether a
> small delay or a forced `didClose`/`didOpen` cycle is needed after edits.
> Track: tally occurrences here → **1/N** (targeted insufficient, full required).

### C25. Symbols → navigate (explore then jump)

1. `lsp_symbols` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`
   - **Expect:** `take_damage` function appears in symbol list. Note its `start_line`.
2. `lsp_definition` — file_path=`res://sv2_validation/sv2_lsp_valid.gd`, line=8, column=1
   - **Expect:** definition.line matches `take_damage`'s start_line from step 1. Confirms the two groups compose naturally.

### C29. Single-file check → whole-project scan → fix → re-scan (project-scope freshness)

The project-scope analogue of C24: a broken script must show up in the *whole-project* scan, and re-scanning after the fix must return it to `clean`. Also confirms the `script_check` → `lsp_project_diagnostics` steering (the single-file compile check points the agent at the project-wide scan for "did I break another script").

1. `script_write` — file_path=`res://sv2_validation/sv2_lsp_c29.gd`, content (broken — unclosed dict):
   ```gdscript
   extends Node2D

   func _ready() -> void:
   	var x = {
   ```
2. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_c29.gd"]`
3. `script_check` — file_path=`res://sv2_validation/sv2_lsp_c29.gd`
   - **Expect:** success=true, `valid`=false, at least one Error diagnostic. The response `hint` steers toward the project-wide compile check (`lsp_project_diagnostics`) for cross-file impact — confirms the single-file → project-scope steering.
4. `lsp_project_diagnostics` (defaults)
   - **Expect:** success=true. `sv2_lsp_c29.gd` appears in `files_with_diagnostics` with a 1-based `line` and `severity:"Error"`. The accounting invariant holds: `scanned == clean + files_with_diagnostics.length + timed_out.length + read_failed.length` (int-coerce each field over the JSON boundary — a whole-dict `_eq` would float the counts).
5. `script_write` — same path, content (fixed):
   ```gdscript
   extends Node2D

   func _ready() -> void:
   	var x = 42
   	print(x)
   ```
6. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_c29.gd"]`
7. `lsp_project_diagnostics` (defaults)
   - **Expect:** success=true. `sv2_lsp_c29.gd` is NO LONGER in `files_with_diagnostics` (it counts toward `clean` now). The invariant still holds.
8. `script_delete` — res://sv2_validation/sv2_lsp_c29.gd

> **REGRESSION WATCH:** the project scan must reflect the *current* on-disk text on
> every call — a stale-cache hit that keeps reporting the broken version after the
> fix (step 7 still shows `sv2_lsp_c29.gd` dirty) is a fan-out freshness bug. The
> scan reads didOpen'd text each call, so the fix must land without a forced
> didClose/didOpen. Mirrors C24's freshness watch at project scope.

---

## Edge Cases

**26.22** Freshness without `editor_refresh`:
1. `script_write` — file_path=`res://sv2_validation/sv2_lsp_fresh.gd`, content: `extends Node2D\n\nfunc test_fresh() -> void:\n\tpass`
2. `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_fresh.gd` (NO editor_refresh between)
3. **Document behavior:** LSP may or may not recognize the file. Both outcomes valid — what matters is no crash/hang. Note: the LSP handler reads file content from disk via `readFile`, so the diagnostics request itself should work — the question is whether Godot's LSP server has indexed the file for cross-file resolution.
4. `script_delete` — res://sv2_validation/sv2_lsp_fresh.gd

**26.23** Freshness with `editor_refresh`:
1. `script_write` — file_path=`res://sv2_validation/sv2_lsp_fresh2.gd`, content: `extends Node2D\n\nfunc test_fresh2() -> void:\n\tpass`
2. `editor_refresh` — file_paths=`["res://sv2_validation/sv2_lsp_fresh2.gd"]`
3. `lsp_diagnostics` — file_path=`res://sv2_validation/sv2_lsp_fresh2.gd`
4. **Expect:** success=true, diagnostics=[] (clean file recognized after refresh)
5. `script_delete` — res://sv2_validation/sv2_lsp_fresh2.gd

---

## Optional Edge Cases (documented — run if time permits)

**OPT-1. LSP_UNAVAILABLE guard:**
Close the Godot editor. Call `lsp_diagnostics` on any .gd file.
- **Expect:** success=false, code=`LSP_UNAVAILABLE`, message mentions "Godot editor"
- Reopen editor after test.

**OPT-2. Reconnect after editor restart:**
Close and reopen the Godot editor mid-session. Call an LSP tool.
- **Expect:** Tool succeeds (lazy reconnect). No stale socket error.

---

## Console error check

Per the [Console Isolation](../tool-sweep.md#console-isolation) protocol.

## Cleanup

- `script_delete` res://sv2_validation/sv2_lsp_valid.gd
- `script_delete` res://sv2_validation/sv2_lsp_bad.gd
- `script_delete` res://sv2_validation/sv2_lsp_minimal.gd
- `script_delete` res://sv2_validation/sv2_lsp_fresh.gd (if exists)
- `script_delete` res://sv2_validation/sv2_lsp_fresh2.gd (if exists)
- `script_delete` res://sv2_validation/sv2_lsp_warn.gd (if exists)
- `script_delete` res://sv2_validation/sv2_lsp_c24.gd (if exists)
- `script_delete` res://sv2_validation/sv2_lsp_c29.gd (if exists)
- `file_delete` res://sv2_validation/sv2_lsp_test.gdshader (if created)
- `discover_tools` with reset=`["lsp_code_analysis", "lsp_code_navigation"]`
