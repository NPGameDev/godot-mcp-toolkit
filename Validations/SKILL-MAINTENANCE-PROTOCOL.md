# Companion-Skill Maintenance Protocol

The durable, reusable ritual for keeping the two CompanionSkills accurate and
proven, run the **same way every time**, across future tool additions, API
changes, and skill-vs-no-skill measurements — **without re-deriving the process
each time a skill is updated.**

This file is the **shared ritual only** — everything that applies to **both**
companion skills:

- `addons/godot_mcp_toolkit/CompanionSkills/godot-mcp-toolkit/` — the main
  toolkit-usage skill (audited + DX-measured in **41q**).
- `addons/godot_mcp_toolkit/CompanionSkills/mcp-extension-creator/` — the
  extension-authoring skill (audited + cold-start-regressed in **41q-bis**).

Where the two skills **diverge** — the regression style, the frozen spec, the
record stamp, the run shape, the gates, the extra checks — the divergences live
in the **arm sub-docs** and are indexed by the **[divergence table](#divergence-table)**
at the end of this file. An agent reading this main file never untangles
interleaved per-skill specifics:

- [`SkillMaintenance/toolkit-skill-arm.md`](SkillMaintenance/toolkit-skill-arm.md) — the 41q arm **as executed**.
- [`SkillMaintenance/extension-skill-arm.md`](SkillMaintenance/extension-skill-arm.md) — the 41q-bis arm.

> **This file is NOT shipped.** It lives in the toolkit repo's `Validations/`
> folder alongside `SWEEP-MAINTENANCE-PROTOCOL.md`, is internal-only, and — unlike
> anything under `addons/` — **may freely reference** `Plan/…` paths, iteration
> numbers, `Methodologies/…` playbooks, and commit SHAs. The shipped skills stay
> self-contained; this maintenance doc does not.

---

## When to run this

Run the full ritual whenever an iteration **updates a companion skill**, and — as
a floor — whenever the surface a skill documents has drifted:

1. **A tool is added, removed, or renamed** — the skill's tool-selection / naming
   surface is now potentially stale.
2. **A tool's parameters change** (added / renamed / removed / re-defaulted) — the
   skill's examples and cribs go stale silently.
3. **The extension API changes** — base class, builder verbs, reserved
   namespaces, registration flow, error contract, annotation semantics.
4. **A guard, error code, or hint changes** — the skill's recovery guidance and
   the regression/cold-start gate values move with it.
5. **Extension-facing user docs drift** — `extending.md` and the two repos'
   `docs/testing-locally.md` extension sections must never contradict the skill.

The audit is **mandatory, not conditional**: even when a skill "looks unchanged",
the audit confirms every claim against current code. The corresponding regression
(DX two-wave for the toolkit skill; cold-start build for the extension skill) is
the **real gate** — a skill that reads correctly but can't drive a working build
still fails.

---

## 1. Delta-window derivation (last skill-touching commit → HEAD)

Every audit is a **delta audit** over a bounded commit window, never a re-read
from scratch.

1. **Find the skill's last-touch SHA.** The commit that last modified any file
   under the skill's folder (`SKILL.md` **or** its `references/`):

   ```bash
   git -C <toolkit-repo> log -1 --format=%h -- \
     addons/godot_mcp_toolkit/CompanionSkills/<skill-name>/
   ```

   Each arm sub-doc records its own last-known window SHA (the analogue of the
   sweep protocol's "Last Known Good SHA") — bump it after every audit.

2. **Enumerate the window.** In each impl repo the skill's surface touches:

   ```bash
   git -C <toolkit-repo> log --oneline <last-touch>..HEAD
   git -C <server-repo>  log --oneline --since=<last-touch-date>
   ```

   Re-anchor at **execution HEAD** — the window computed at grill time is a
   snapshot; anything that landed after it is still in scope.

3. **Classify each commit** as skill-visible (a behavior/param/naming/contract
   change a user or agent relies on) or not. Skill-visible commits become audit
   line-items; the rest are noted and dropped.

4. **The floor is not the ceiling.** A pre-verified "known-stale items" list (if
   the iteration ships one) is a **floor** — the executor still runs the full
   audit categories below as a delta audit and finds anything the floor missed.

---

## 2. Audit categories — code is the SSOT

The skill's prose is **never** the source of truth. Every claim is verified
against live code, and where a documented list must mirror a code constant, the
rule is **verbatim match, code wins**.

| Skill claim | Code SSOT (verify against) | Rule |
|-------------|----------------------------|------|
| **Builder verbs** (`mark_*` / `with_*` table, decision table) | `addons/godot_mcp_toolkit/contract/mcp_toolkit_command_options.gd` | Every builder method has a row; no verb documented that the class doesn't expose; no author-facing `is_*` (internal dict key + registry getter only). |
| **Reserved namespaces** | `addons/godot_mcp_toolkit/extensions/services/extension_support.gd` → `RESERVED_PREFIXES` | The documented list matches the constant **verbatim** — same count, same entries. A drift (e.g. a missing `autoload.*`) is a code-vs-doc bug. |
| **Wire-vs-MCP-tool naming** | server `src/extensions/extensionCommand.ts` → `toolNameFromMethod` | A wire method `a.b` surfaces as the MCP tool `a_b` (dot → underscore). Use the **MCP tool name** wherever the agent/user is the caller; wire names only inside `registry.add(...)` context. The skill teaches the conversion + a pitfall row. |
| **Error contract** | `addons/godot_mcp_toolkit/contract/mcp_toolkit_error.gd` | Error helpers named correctly (`MCPToolkitError.fail(code, message, hint = "")`); no phantom helpers; the optional `hint` arg is load-bearing for recovery. |
| **Meta / eager tool names** the skill cites | server `src/registration/catalogue.ts` | Agent-facing meta tools (`extensions_refresh`, `discover_tools`) are always eager — cite them by their MCP name, not the wire name. |
| **Tool selection / renames** | the server `src/tools/*.ts` wire definitions | Grep the skill for every old parameter/tool name in the delta window; the code's wire name is truth even when a docs pass disagreed. |

**Extension-facing docs sweep — part of the same pass.** Staleness fixes are not
skill-only: anything a user relies on to extend the toolkit is corrected in the
same audit (user directive 2026-07-21):

- `addons/godot_mcp_toolkit/docs/extending.md` (**shipped**) — apply every
  code-SSOT correction that touches it; keep it self-contained (no `Plan/` /
  `docs/dev/` refs).
- Toolkit `docs/testing-locally.md` §"Testing an extension" (repo-level,
  Pages-served) — align the skill's self-check wording with it so the two
  surfaces never contradict.
- Server `docs/testing-locally.md` extension section — grep-verify; a surfaced
  staleness there is one small `docs(server)` commit (I8: one commit per repo
  touched).

---

## 3. Statelessness, the 500-line cap, and `references/`

Users sync an updated skill by **replacing the folder** — so the skill must carry
no state and stay within the authoring budget.

- **Statelessness.** No project- or machine-specific state (paths, ports beyond
  documented defaults, project names); no instruction that writes state into the
  skill folder; **no drift-prone embedded totals** (tool counts, exhaustive group
  lists — keep such lists explicitly *examples*, with the live source named, e.g.
  "`discover_tools()` lists the full catalogue"). **No version field inside the
  skill** — the addon version *is* the skill version (see §4).
- **500-line hard cap on `SKILL.md`** (the skill-creator rule). The `references/`
  files are **excluded** from the cap.
- **`references/` handling — progressive disclosure, not content loss.** When the
  cap is threatened, split depth into `references/*.md` (minority paths, deep
  setup, long tables) and keep inline the golden-rule mini-version + the pitfall
  that must survive even if the reference is never read. Both skills follow this
  pattern; the specific split lives in each arm's `§B`-equivalent.
- **Whole-folder install (shared integration check).** The CompanionSkills
  install path (dock button / manual copy) **must copy the entire skill folder,
  `references/` included** — if it copies only `SKILL.md`, the split silently
  lobotomizes installed skills. Verify once; fix in whichever skill-update
  iteration first ships a `references/` split.

---

## 4. Addon-version = skill-version stamping

Neither skill carries its own version field. **The addon version (`plugin.cfg`)
is the skill version** — a single version surface, matching the 41r
single-version-surface rule. Consequences:

- The regression/cold-start record row stamps the skill as
  `skill=<arm>@<plugin.cfg version>` (the arm sub-doc fixes the `<arm>` token).
- The record row's **toolkit SHA disambiguates** pre-release states that share a
  `plugin.cfg` version.
- Users update a skill by replacing the folder; there is no in-skill version to
  bump.

---

## 5. The DX / regression record

Both arms write their measured outcome into the **same historical record**:

- **Record:** `Plan/ExecutionPlan/Validations/DX-REGRESSION-RECORD.md` (plan repo).
- **Per-run artifacts:** `Plan/ExecutionPlan/Validations/DXRuns/<date>-<serverSHA>/`
  (plan repo), per the report shape in the plan repo's
  `Methodologies/dx-regression-evaluation.md` §4.1.
- The shared instrument is that protocol's extractor
  (`Plan/Benchmarks/scripts/extract-dx-metrics.py`), run with the per-arm flags
  the arm sub-doc names.

> **Open packaging question (do NOT solve here).** The record + `DXRuns/` live in
> the **plan repo today**. Whether the record's durable home should move (e.g.
> alongside the shipped repos, or into a release-artifacts location) once the
> project is released is an **open 41r/42 packaging question** — flag it there,
> not in this protocol. Until then: plan repo, path above.

---

## 6. Ritual outline (both skills)

1. **Read the current skill** (`SKILL.md` + `references/`).
2. **Derive the delta window** (§1) in both repos; re-anchor at execution HEAD.
3. **Run the audit categories** (§2), code as SSOT; sweep the extension-facing
   docs in the same pass.
4. **Update the skill** — corrections + new content, honoring statelessness + the
   500-line cap + `references/` handling (§3).
5. **Run the regression** — the arm-specific gate (DX two-wave *or* cold-start
   build; see the divergence table).
6. **Fix issues** the regression surfaces; land skill fixes as a **new** commit
   (never amend a pushed commit).
7. **Static-check** any code touched during testing
   (`validate_gdscript.sh` with `GODOT_BIN` set — never bare `--check-only`,
   which is a vacuous no-op; `npm run build` for server changes).
8. **Record + report** into the shared DX record (§5), stamping
   `skill=<arm>@<plugin.cfg version>` (§4).
9. **Bump the arm sub-doc's last-window SHA** so the next audit's delta window
   starts from the right place.

---

## Divergence table

One row per divergence axis; each cell links into the owning arm sub-doc, where
the per-skill specifics live. **No per-skill detail belongs in this main file** —
if a value differs between the two skills, it is here as a pointer only.

| Divergence axis | Toolkit skill (41q) | Extension skill (41q-bis) |
|-----------------|---------------------|---------------------------|
| **Regression arm** | Full-game DX regression — [Stellar Siege, two-wave same-HEAD](SkillMaintenance/toolkit-skill-arm.md#regression-arm) | [Cold-start extension **build**](SkillMaintenance/extension-skill-arm.md#regression-arm) — agent builds a working extension from the skill alone (no game) |
| **Frozen spec** | [Frozen Stellar Siege prompt](SkillMaintenance/toolkit-skill-arm.md#frozen-spec) (owned by the DX protocol) | [Frozen task spec **v1**, verbatim](SkillMaintenance/extension-skill-arm.md#frozen-task-spec-v1-immutable) — durable, immutable home here |
| **Record stamp** | [`skill=companion@<plugin.cfg version>`](SkillMaintenance/toolkit-skill-arm.md#record-stamp) | [`skill=extension@<plugin.cfg version>`](SkillMaintenance/extension-skill-arm.md#record-stamp) |
| **N & wave shape** | [Two waves ×3 parallel, same HEAD](SkillMaintenance/toolkit-skill-arm.md#n--wave-shape) (wave 1 `skill=none`, wave 2 `skill=companion`); delta = wave-2 − wave-1 medians | [N=1, sequential, Sonnet-pinned, two-phase](SkillMaintenance/extension-skill-arm.md#n--wave-shape) (binary gate, no baseline arm) |
| **Gates** | [Tier-1 (regression 20/20 · Type-A 0 · completeness ≥ Sonnet floor) + Tier-2 banded delta](SkillMaintenance/toolkit-skill-arm.md#gates) | [Tier-1 binary (loads · registers · works · 0 interventions · Type-A analogue 0)](SkillMaintenance/extension-skill-arm.md#tier-1-gates-all-binary) + seeded Tier-2 |
| **Extra checks** | [Two-instrumentation-rule prompt · eager-manifest cross-check · same-surface guardrail](SkillMaintenance/toolkit-skill-arm.md#extra-checks) | [Pre-flight harness check · `--requirements 3` · guided-mode live dry run](SkillMaintenance/extension-skill-arm.md#extra-checks) |
