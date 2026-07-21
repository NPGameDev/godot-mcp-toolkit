# Extension-Skill Maintenance Arm (41q-bis)

The per-skill divergences for the **extension-authoring** companion skill,
`addons/godot_mcp_toolkit/CompanionSkills/mcp-extension-creator/`. Read the
[shared ritual](../SKILL-MAINTENANCE-PROTOCOL.md) first; this file holds only the
axes that differ for this skill, linked from the shared file's divergence table.

> **Origin.** This arm's method was ratified at the 2026-07-21 formal grill and is
> specified in the **41q-bis iteration file**
> (`Plan/ExecutionPlan/41q-bis-extension-skill-update.md`, "Pre-grill §A" as
> amended inline) over the **DX Regression Evaluation Protocol** (plan repo
> `Methodologies/dx-regression-evaluation.md`, the `skill=extension@<ver>` arm).
> This file is the **durable, immutable home of the frozen task spec v1** — the
> spec below is copied verbatim and must not be edited.

---

## Regression arm

A **cold-start extension *build*** — not a game build. A fresh `claude -p` agent,
with no prior context and only the extension-creator skill installed, builds a
working MCP toolkit extension from the skill's guidance alone. Mirrors the
41k-bis-et-tricies cold-start methodology, adapted for extension-building: it
adopts the DX protocol's **two-phase clean build + objective transcript-derived
metrics + the same historical record**, with an *extension-specific* completeness
checklist (extension loads · tools register · tools work) in place of the game
requirements. **No agent self-scoring.**

## Frozen task spec (v1, immutable)

Copied **verbatim** from the 41q-bis iteration file, "Pre-grill §A". Frozen at the
2026-07-21 grill; immutable across future re-runs, like the Stellar Siege prompt.
This is its durable home — do not edit.

> Using the tools and the mcp-extension-creator skill available to you, build an MCP toolkit
> extension named `project_notes` that adds two custom tools: (1) `notes.write` — writes a
> markdown note to a `res://` path given in `file_path`, with `content` as the second
> parameter; validate both, guard the path. (2) `notes.list` — lists existing `.md` notes
> under a `res://` folder parameter; read-only and idempotent. Put `notes.list` in a tool
> group named `notes`. Both tools must follow the toolkit's error contract. Prove both work
> end-to-end by calling them through MCP, including one invalid-input call each and, for
> `notes.write`, one path-traversal attempt (a path that escapes `res://`) — show it is
> rejected.

This spec exercises the highest-risk skill surfaces: base class + `register()`,
input schema, declarative `guard_project_path`, `mark_read_only` /
`mark_idempotent` (and whether the skill's decision table steers
`mark_scene_independent` for file-only tools), `with_group` + keywords, error
contract, hot-reload/refresh, and grouped-tool discovery.

**Deliberate properties (do NOT "fix" at execution):**

- The spec speaks **wire names only** (`notes.write`) — discovering that the MCP
  surface lists `notes_write` (dot → underscore) is part of what the run probes,
  now that the skill teaches the conversion.
- The one-grouped / one-ungrouped split is intentional — it exercises both the
  eager path and the `discover_tools` path.
- The traversal sentence names **no error code** — teaching the contract is the
  skill's job; the orchestrator checks for `PATH_DENIED` in the transcript
  (Tier-1 gate 3).

## Record stamp

`skill=extension@<plugin.cfg version>` (the addon version is the skill version —
shared ritual §4). Game column: `extension-build (frozen spec v1)`. The toolkit
SHA disambiguates pre-release states. **This is the first `extension` arm row** —
seed the Tier-2 columns.

## N & wave shape

**N=1, sequential (solo), Sonnet pinned, two-phase.** One clean
`claude -p --model sonnet --output-format stream-json --verbose` build (Phase A);
the orchestrator judges post-hoc (Phase B). Stamp
`concurrency-mode: sequential`.

**Why N=1 here (and why that is not a shortcut).** The gate is a **binary
completeness** check on a *small* task, not a variance-sensitive trend — one leg
is enough. This is the asymmetry with the toolkit arm (41q), which measures a
**delta** (skill vs no-skill at the same HEAD) where medians are needed, so it
runs two waves ×3. Because this arm has **no baseline arm**, N=1 is correct.
**State this asymmetry in the record row** so N=1 doesn't read as a corner cut.

Record the resolved provider / model-name / version / model-id per the DX
protocol's record columns (row-1 precedent: `claude-sonnet-5`). Pipe mode is
viable end-to-end: `discover_tools` group activation works in `-p` (verified
2026-07-13) and `extensions_refresh` gives a focus-free rescan.

**Environment:** fresh minigames clone with the synced toolkit addon (same clone
infra + clone-`CLAUDE.md` handling as the DX runs), Godot 4.5 editor running, the
updated skill installed **whole-folder** at `.claude/skills/mcp-extension-creator/`
(`references/` included), and `.claude/skills/` stripped to **only** that folder —
no other skills present.

## Tier-1 gates (all binary, orchestrator-judged)

1. **loads** — discovered by the reflection loader, no parse errors.
2. **registers** — both tools callable; the grouped one appears after
   `discover_tools`.
3. **works** — happy path returns the success envelope; invalid input returns
   `INVALID_PARAM`; a traversal path is rejected with `PATH_DENIED`.
4. **zero manual interventions.**
5. **Type-A analogue = 0** — the agent never bypassed the extension API (no edits
   to `addons/godot_mcp_toolkit/`, no hand-registration around the builder).

**Tier-2 (seeded — first `extension` arm row):** total calls, confusion ratio,
tokens, duration from `extract-dx-metrics.py`, **run with `--requirements 3`**.
The flag already exists; its default (14) is Stellar-Siege-specific. Stamp the
row: *"per-req basis: 3-item extension checklist (loads · registers · works) —
not comparable to game-run per-req numbers."*

**If the build fails:** identify whether the failure is in the **skill** (bad
guidance) or the **extension API** (unexpected behavior); fix the skill and/or API
as appropriate; re-run the relevant portion. Skill fixes land as a **new** commit
(never amend a pushed commit).

## Extra checks

- **Pre-flight harness check (runs BEFORE the measured leg).** In a throwaway
  `-p` session against the prepared clone, hand-drop a one-tool fixture
  extension, call `extensions_refresh`, then call the fixture tool. This proves
  the pipe-mode client surfaces **newly-registered extension tools** end-to-end
  (the 2026-07-13 verification covered `discover_tools` group activation, not the
  mid-session extension-registration path). If the pre-flight fails → **halt and
  investigate the harness; never burn the measured leg on it.** Delete the fixture
  (and any residue) before the measured run.
- **`--requirements 3`** — the 3-item extension checklist (loads · registers ·
  works) is the completeness basis for `extract-dx-metrics.py`, replacing the
  game's 14-requirement default.
- **Guided-mode live dry run — one interactive run, NOT a matrix.** After the
  cold-start gate passes and any fixes land, the user opts in from a normal
  `claude` session in the dogfood toolkit project and designs a **1-tool**
  extension end-to-end (intent Q&A → single annotated draft → adjust-by-line).
  Confirm correct annotations with rationale and an internally consistent draft.
  The designed extension is a **throwaway — deleted before commit**; pick an idea
  other than `project_notes` so the draft isn't primed by cold-start artifacts.
  The cold-start pass is the **release gate**; guided mode is bounded validation
  (per the iteration's "Guided authoring mode" disposition — role-play was
  dropped, since it softballs exactly the interaction quality under test).

## Record + report

One row in `DX-REGRESSION-RECORD.md`, stamped as above; per-run artifacts in a
`DXRuns/<date>-<serverSHA>/` directory (plan repo — shared ritual §5). The report
can be **lean** (one leg). Gzip the transcript into the run dir; snapshot the
built extension per the protocol's durable-artifact steps.

## Last audit window SHA

The next extension-skill audit derives its delta window (shared ritual §1) from
the skill's last-touch commit. **Extension skill last touched (pre-41q-bis):**
`5cc38c3` (2026-07-03) — the delta window this iteration audits. Bump this to the
41q-bis skill-update commit once it lands, and after each future extension-skill
audit.
