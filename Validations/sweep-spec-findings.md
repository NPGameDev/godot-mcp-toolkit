# Sweep spec findings — deferred for end-of-run review (41n-ter)

**Process (per user, 2026-06-29):** During the live sweep run, do NOT edit sweep
specs for newly-found inconsistencies. Collect them here and present them 1-by-1 to
the user at the END of the run; the user decides/applies. Changes already applied
earlier this run are KEPT (not reverted). This ledger is for TEST-DOC / sweep-
structure inconsistencies. PLUGIN/behavior deviations are separate and continue to
route to **41n-ter-bis** via the RESULTS.md rows.

## Already applied this run (keep — do NOT revert, per user)
- **S11.7** — byte-paging fixture 1000B → 10B (context-bloat fix; spec note added).
- **S15.9** — spriteframes frames trimmed (idle 2→1, run 4→2) — bloat fix (from audit).
- **S17.10** — added `class_filter=Node` to the scene_query NOT_FOUND guard (was filterless = dup of 17.9; tool verified correct, NOT_FOUND reachable only with a filter present).
- **S19** — tool-name `collision_from_sprite` → `collision_from_texture` (stale name); cleanup note corrected (generated CollisionPolygon2D is a *sibling* of the sprite, not a child).
- **S20** — runtime paths `Sv2Main` → `main` and `current_scene.name` `"Sv2Main"` → `"main"` (verified live: main.tscn root node is `main`).

## Deferred findings — ✅ ALL APPLIED in a standalone fix (2026-06-30)

*D1–D7 below were applied to the `Sections/` specs (40 `main.tscn`→`Sv2Main.tscn` renames across 18 files + the `20-runtime.md` `/root/main`→`/root/Sv2Main` revert + targeted edits). Kept here as the record of what changed and why. Companion toolkit-side items (D7's no-script-tab-close API, etc.) remain routed to 41n-ter-bis.*

### D1 — Test-scene root naming / throwaway "Sv2Main" scene  (raised by user)
The sweep's main test scene is `res://sv2_validation/main.tscn`. `scene_create`
names the root by filename stem (no `root_name` param — confirmed S17.1), so the
root node is **`main`** — ambiguous with the toolkit's real main (`res://Main.tscn`)
and the reason the section docs' `/root/Sv2Main/...` paths didn't match. **User's
idea:** create a clearly-named throwaway scene whose ROOT is `Sv2Main` so runtime
paths are unambiguous and there is zero confusion/risk vs the real main.
*Impl notes:* to get a `Sv2Main` root via `scene_create` (no root_name param) the
file stem must match (e.g. `sv2_main.tscn` → root `sv2_main`), OR rename the root
node after create, OR add a `root_name` param to `scene_create`. Touches S1
(scaffolding) + every section using a `main.tscn` root path (S2, S16, S17, S20,
S22, …). This supersedes the S20 `Sv2Main→main` path edit if adopted.

### D2 — S21.3b: "parse error in runtime log" expectation is optimistic
21.3b expects `debugger_get_log` (right after launching a scene whose main-scene
script has a PARSE error) to contain the GDScript parse error in `lines`. Reality:
a main-scene script that fails to compile crashes the game pre-runtime-connection,
so no output cache is built and `debugger_get_log` returns `GAME_NOT_RUNNING`; the
parse error surfaces in the editor console / error hint, not the runtime log.
Suggested refine: 21.3b should expect `GAME_NOT_RUNNING` (or check the editor
console for the parse error) for a compile-failing main scene. (The tool-side
question — should `debugger_get_log` serve the editor-console error here — is
separately routed to 41n-ter-bis via the S21 RESULTS row.)

### D3 — S22.C10 step 3: `node_management` group does not exist
C10's keyword-search step expects `request="rename node"` → "node_management
activated". Reality: `node_manage`/`node_groups` are **CORE** tools (worked in C8
with no activation); there is no `node_management` on-demand group in this build's
catalog, so the keyword returns 0 groups. Refine C10 step 3 (drop the
node_management expectation, or treat node management as core). (Tool/arch side —
whether such a group should exist — is routed to 41n-ter-bis via the S22 row.)

### D4 — S22 cleanup-verify: `asset_list` lags `resource_delete` deindex
The final cleanup-verify (`asset_list` name_glob=`c*` → expect none) gave a false
"leftover": `c6_ts.tres` still appeared after C6's `resource_delete` returned
`deindexed:true`; only a full `editor_refresh` cleared the EditorFileSystem-backed
view (file was physically gone). Suggested refine: cleanup-verify should
`editor_refresh` before the `asset_list` check. (The asset_list/EditorFileSystem
lag itself is routed to 41n-ter-bis via the S22 row.)

### D5 — S25 UR12.2: texture `value` shown as a bare string
UR12.2 sets `node_set_property` texture `value=res://icon.svg` (bare string), but
the live schema rejects bare strings (INVALID_VALUE, per FIX-F); it must be
`{"type":"Resource","path":"res://icon.svg"}`. Refine UR12.2 to the Resource-ref
shape. (Separately, UR1.6 "redo doesn't restore the value" and UR2.2 "original-path
undo lookup after rename fails" are behavior FAILs routed to 41n-ter-bis via the
S25 row — tool vs test-helper vs spec-expectation is for the dev pass to triage,
not a clear spec edit.)

### D6 — S26.17–21: LSP definition/references path format is `file:///…` (ledger#4)
`lsp_definition`/`lsp_references` return `file_path` as `file:///C%3A/…`
(globalized-absolute URL), NOT `res://`. This is consistent with **ledger#4
(token-path authority — publish globalized-absolute)**, i.e. the NEW intended
behavior, so the tests' `res://` expectation is stale post-ledger#4. Update
26.17/18/20/21 to expect the globalized-absolute form (lines were all correct);
26.19 also returns `[]` not `null` for an engine class. Minor companion: 26.10
expects shader symbols but the LSP parses `.gdshader` as GDScript and returns `[]` —
consider accepting `[]`/SKIP for shader symbol/diagnostic tests until shader-LSP
support exists. (Both also routed to 41n-ter-bis via the S26 row.)

### D7 — Orphaned script tab blocks folder_delete (no script-tab close API)
S22's C5 created `c5_script.gd`, attached it via `node_set_script`, then `script_delete`d
the FILE — but the script-editor TAB stayed open. At Last-cleanup, `folder_delete
res://sv2_validation/` was refused with `PATH_IN_USE` ("contains open script
c5_script.gd; close the script editor tab manually — no programmatic close API"). The
file was already gone; the orphaned TAB is the blocker. Workaround used: deleted every
file individually (folder is now physically empty — Glob confirms — so the git state is
clean; empty dirs aren't tracked). Gaps: (a) **toolkit** — `script_delete` leaves an
orphaned script-editor tab and there's NO programmatic script-tab close API, so
`folder_delete` can be permanently blocked → 41n-ter-bis (have `script_delete` close the
tab, or add a close-script-tab tool); (b) **Last-cleanup spec** should delete files
individually as a fallback and note the empty-folder/orphaned-tab residue clears only on
manual tab close / editor restart.
