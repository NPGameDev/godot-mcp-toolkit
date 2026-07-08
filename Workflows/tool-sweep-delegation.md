# Spec: Delegated MCP tool-sweep runner

## What the sweep is
`Validations/` holds: `tool-sweep.md` (index + protocol), `Sections/NN-*.md`
(per-section test specs), `RESULTS.md` (output table + resume tracker). A run
executes sections 0–28 sequentially against a live Godot editor with the MCP
plugin (port 6550). Historically driven inline; **delegation** offloads each
section to a `sonnet` builder so the orchestrator context stays lean (tier
lowered from opus 2026-06-29 once briefs became fully self-contained — see step 6
+ README tier note; escalate subtle sections like S22 back to opus).

## Why delegation stalled (2026-06-29 lessons)
- Agent #1 hung on `Bash(node -e "...'A'.repeat(1000)...")` building a fixture
  → **forbid Bash entirely** in the brief.
- A 1000-byte fixture bloated context → **trimmed S11 spec to 10 bytes**; keep
  all fixtures tiny.
- A 7-call MCP batch stalled the client UI on the last call → **2–3 calls/msg**.
- Agents that fetch context (read tool-sweep.md / section files) are slow and
  stall-prone → **embed everything in the brief; agent Reads only RESULTS.md**.
- **Background agents CAN reach the MCP server** (confirmed S12–S14) — the stall
  was Bash-specific, not MCP. So delegation is viable once Bash is off the table.

## How to delegate one section (proven procedure)
This is the per-section loop. The orchestrator does the cheap prep so the agent
does zero lookups.

1. **Read the section file** (`Sections/NN-*.md`) yourself — it's small. Note its
   test count, dependencies, REGRESSION WATCH IDs + severities, and cleanup.
2. **Activate the section's tool group(s) WITH schemas** and reset the previous
   section's group in the same call:
   `discover_tools(request:[new groups], reset:[prev section group], include_schemas:true)`.
   Keep `cleanup`/`resource_io`/`editor_advanced`/`asset_ops` active all run.
3. **Extract param drift from the returned schemas — THIS IS THE KEY STEP.** The
   section prose often uses different param names than the real tool. Diff them
   and bake the *real* names into the brief. Misses here cause false FAILs.
   Drifts found this run:
   | Section | Section prose says | Real schema param |
   |---------|-------------------|-------------------|
   | S11 save_* | `save_path` | `path` |
   | S13 animation_keyframe | `node_path`/`animation`/`track_property` | `player_path`/`animation_name`/`track_path` (+ required `action`) |
   | S13 animationtree_* | — | `node_path` |
   | S14 tilemap_set_cells | — | `node_path` |
   | S14 tilemap_read_cells | — | `node_path` |
   | S14 tileset_*/edit_* | — | `file_path` (+ `source_id`, `tiles[]`) |
   **Caveat — schema desc ≠ enforced schema:** discover_tools *descriptions* can
   disagree with the enforced MCP/zod layer (e.g. S15.6 `audiobus_edit.effect`
   self-describes as a string but is enforced as an object `{type}`). Frame drift
   notes as HINTS: tell the agent to trust the live validation error and try the
   alternate shape if the stated one fails, then flag the resolved form.
4. **Check fixture dependencies** and give the agent a fallback. Fixtures created
   in earlier sections may be bare. Examples: `anim_lib.tres` is an EMPTY
   AnimationLibrary by design (S13's keyframe auto-creates the animation —
   expected, not a bug); `Sv2TileLayer` may need its `tile_set` assigned before
   S14.18 (give a `node_set_property` fallback). Tell the agent to report a real
   regression rather than mask it by hand-seeding.
5. **Carve discover_tools exceptions** when a section *tests* activation itself
   (S14's 14.26–14.28 verify group tool counts). Allow discover_tools for exactly
   those tests; forbid it everywhere else (incl. no `reset`).
6. **Compose the brief from the template below** and spawn ONE `sonnet`
   **background** agent (`run_in_background:true`, `subagent_type:claude`,
   `model:sonnet`). Background lets you TaskStop if it wedges; foreground would
   freeze the session. Escalate `model:opus` only for a section whose correctness
   hinges on subtle multi-step reasoning the brief can't fully pre-specify (e.g.
   S22 combo chains) — since the orchestrator reviews summaries, not raw output,
   any regression-recognition the brief doesn't make mechanical must be caught by
   the agent itself.
7. **On the ≤25–30-line report:** verify counts, confirm the RESULTS row landed
   as a single well-formed 6-column row (no literal `|` inside the notes cell
   breaking the table) and that no other row was touched, record any
   FAIL/deviation, then go to the next section. Do NOT read the agent's transcript
   file (it overflows context).

## Reusable brief template
```
You are the BUILDER for <<Section N — Title>> of an MCP tool-sweep — one seat in
a sequential sweep, NOT the orchestrator. Autonomous: resolve ambiguity by
most-likely pick and flag it; hard-stop only on the conditions below.

⛔ NO SHELL: never use Bash/node/any shell command for ANY reason (background
agents hang on Bash permission prompts). MCP tools + Read/Edit ONLY.
⛔ DO NOT LOOK THINGS UP: everything is in this brief. Do NOT read tool-sweep.md,
the section files, or CLAUDE.md; do NOT call discover_tools <<except 14.26–14.28
style activation tests>>. Your ONLY file Read is RESULTS.md (once, to append).

SWEEP CONTEXT: 41n-ter Pass-3, Godot 4.5, MCP server `godot-mcp-toolkit` port
6550, GDScript project. <<scene/nodes/resources the section needs>>.

TOOLS (already activated server-side by the orchestrator): load schemas with ONE
ToolSearch call: query "select:<<full mcp__godot-mcp-toolkit__ names + editor_get_console>>".
Full prefixed names; deferred-cache misses are still callable; FAIL only on a
real "method not found". ⚠️ PARAM DRIFT: <<exact real param names per step 3>>.
<<compact signature + key return fields per tool>>

CONSOLE ISOLATION (mandatory): SETUP before first test = editor_get_console clear_buffer=true;
CHECK after last = plain read, scan literal "UndoRedo history mismatch" (FAIL only
on that; intentional guard errors are fine).

PRE-STEP: <<scene_open the dependency scene if node paths must resolve>>.

TESTS (run ALL — mandatory; batch 2–3 calls/msg): <<every test verbatim with the
REAL params + Expect lines + REGRESSION WATCH IDs/severities>>. Uniform pagination
contract (ledger #9): total_<unit> + truncated ALWAYS present; next_offset + hint
ONLY when truncated.

CLEANUP: <<section cleanup steps>>. Do NOT reset tool groups (orchestrator does).

RESULTS ROW: Read C:\...\godot-mcp-toolkit\Validations\RESULTS.md. Find the LAST
data row in "## Section Results" (starts "| <<S(N-1) — prev title>> |"). Edit:
old_string = that full row; new_string = same + newline + your row. Touch nothing
else. Match prior rows' terse, info-dense, cite-IDs style. REPORTING FORMAT — the
appended row MUST be a SINGLE well-formed markdown row with exactly 6 columns;
inside the notes cell use `/` or `;` as separators, NEVER a literal `|` (a stray
pipe spawns extra table columns and corrupts the whole table). Format:
| <<S N — Title>> | <total> | <passed> | <failed> | <skipped> | <notes> |

CAVEATS: flag any FAIL prominently with its watch severity; deviations route to
41n-ter-bis (do NOT fix source). MCP only for Godot ops; never edit
.tscn/.gd/.tres; paths res:// only; don't touch user://addons/godot_mcp_toolkit/.
Clear doc-drift (wording) not a regression → PASS + note.

DO NOT: use Bash; read files other than RESULTS.md; call discover_tools <<except
noted>>; run other sections; modify other RESULTS rows; finalize the report;
commit; address the user.

STOP & REPORT when the section is done + row appended, OR a hard-stop ("method not
found" on a real call ⇒ BLOCKED; a UndoRedo mismatch). A single test FAIL does NOT
stop the section — log it and continue.

RETURN (≤25–30 lines): pass/fail/skip counts; one-liners for non-PASS tests;
regression-watch outcomes (GREEN/regressed + severity); paste the appended row;
console clean (mismatch y/n); deviations flagged for 41n-ter-bis.
```

## Sweep-specific reference
- Uniform pagination contract (ledger #9): total_<unit> + truncated ALWAYS
  present; next_offset + hint ONLY when truncated. **Known regression this run:**
  classdb offset pagination (S12.6/12.7) mis-sets `truncated` at the
  offset-at/past-end edge → routed to 41n-ter-bis.
- Batch rollup (concern-034D): partial failure → top-level `failed`(int)+`hint`;
  all-success → both keys ABSENT.
- Idempotency `status`: created / returned / replaced.
- **S23 (C#) → SKIP. S24 (Extensions) → no editor restart on 4.5** (4.2-only).
- post-#3 CQS tools to confirm: `animationtree_list` (S13, GREEN), `audiobus_list` (S15).
- **S24 dynamic extension-tool calls — the recipe (agents WILL falsely report BLOCKED without it).** After `extensions_refresh` registers an extension's commands, the runtime tools do NOT auto-surface as deferred tools, and guessing/keyword-searching the name fails. To CALL one: (1) `discover_tools(request:["<ext_group>"], include_schemas:true)` → returns the EXACT exposed name (dots→underscores, e.g. `sv2_ext.hello` → `sv2_ext_hello`) + schema; (2) `ToolSearch select:mcp__godot-mcp-toolkit__<exact_name>` → loads the schema AND surfaces it as a callable deferred tool; (3) call it. Bake this into the S24 brief. Verified 41n-ter: E3 + E10a–d all callable this way (the first S24 run mis-reported them BLOCKED after guessing names).
  **41n-octies UPDATE — the recipe FAILS from a background subagent.** A subagent's
  ToolSearch deferred-index is frozen at spawn and never absorbs the mid-session
  `tools/list_changed` from `extensions_refresh`/`discover_tools`, so a delegated
  S24 agent genuinely CANNOT call `sv2_ext_*` (control: `select` of a base tool
  like `script_check` loads, but `select` of the ext tool returns "No matching
  deferred tools"). Same gap hit **S28**: `placeholders` activated by 28.8 →
  `texture_generate`/`sound_generate` uncallable from the subagent. FIX: the
  **interactive orchestrator session DOES absorb** them, so the orchestrator runs
  the call-path tests inline and edits the row (recovered S24 E3/E10a-d + S28
  28.9-28.19 this run). Corollary for on-demand GROUPS whose tools the subagent
  must CALL (not dynamically-registered): **orchestrator PRE-ACTIVATES the group
  BEFORE spawning** so it's in the subagent's spawn-time index (a section test that
  re-activates then just sees `already_loaded`).

## Final steps (end of sweep — after S28 + Last-cleanup)
1. Run `Sections/Last-cleanup.md` to delete all `res://sv2_validation/` artifacts.
2. Finalize `RESULTS.md`: flip Status → COMPLETE, add the Total line, the
   `## Regression Watch Results` table, and the `## Pitfalls Discovered` table.
3. Restore original project state (name/main_scene; discard stray `project.godot`
   layout diff if not intended).
4. **COMMIT** (user-requested): `Validations/RESULTS.md` + the tool-sweep spec
   edits (e.g. `Sections/11-save-system.md` fixture trim, any other section-doc
   fixes) + the `Workflows/` docs. On the default branch (`main`), prefer a branch
   first per harness policy unless the user says commit to main directly — the
   repo's history is direct-to-main, so confirm at commit time.
