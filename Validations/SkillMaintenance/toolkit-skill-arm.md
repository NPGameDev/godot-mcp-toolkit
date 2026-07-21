# Toolkit-Skill Maintenance Arm (41q, as executed)

The per-skill divergences for the **main toolkit-usage** companion skill,
`addons/godot_mcp_toolkit/CompanionSkills/godot-mcp-toolkit/`. Read the
[shared ritual](../SKILL-MAINTENANCE-PROTOCOL.md) first; this file holds only the
axes that differ for this skill, linked from the shared file's divergence table.

> **This is a capture, not a definition.** The origin of this arm's method is:
> - the **41q iteration file** — `Plan/ExecutionPlan/archive/41q-mcp-toolkit-skill.md`
>   (its **§G Grill outcome** and **Outcome** sections are the executed record);
> - the **DX Regression Evaluation Protocol** — plan repo
>   `Methodologies/dx-regression-evaluation.md` (the shared instrument).
>
> When those two disagree with anything below, **they win** — this file exists so
> a future toolkit-skill audit doesn't re-derive the shape, not to restate the
> protocol.

---

## Regression arm

A **full-game DX regression** through the whole toolkit, not an
extension-specific build. The skill is measured by driving an end-to-end game
build and subtracting a skill-free baseline measured on the **same surface**.

- **Game: Stellar Siege** — the canonical broad-exercise game (TileMap star
  field, rotating turret, 3 multi-instanced enemy types, projectiles, resource
  management, 5 waves + boss, power-ups, procedural SFX, HUD, autoload, 5
  collision layers). Rationale + what it exercises: DX protocol §1.
- **Instrument:** the DX Regression Evaluation Protocol run as a two-wave design
  — objective transcript-derived metrics, **no agent self-scoring anywhere**.

## Frozen spec

The frozen **Stellar Siege prompt** is owned by the DX protocol, not copied here:
DX protocol §1 → the verbatim block in
`Plan/ExecutionPlan/archive/41k-nonis-et-vicies-final-dx-validation.md` under
"Game specification". Reused verbatim with exactly two modifications (remove the
old 10-section DX-REPORT harness; add the two instrumentation rules — MCP-tools-only
+ cache-miss recovery). The prompt is **byte-identical across both waves** — the
installed skill is the only delta.

## Record stamp

`skill=companion@<plugin.cfg version>` (the addon version is the skill version —
shared ritual §4). Game column: the Stellar Siege build. As executed in 41q the
skill was `companion@1.0.0`; the toolkit SHA disambiguates pre-release states.

## N & wave shape

**Two waves at the same HEAD, ×3 parallel each** (grill decision 2026-07-21, Q1):

- **Wave 1 — `skill=none` ×3 parallel.** Re-seeds the skill-free band on the 1.0
  surface **and** doubles as a pre-release product-regression gate (the skill
  isn't installed).
- **Wave 2 — `skill=companion@<ver>` ×3 parallel.** Same product surface, same
  certified `parallel(3)` mode; the updated skill installed whole-folder
  (`references/` included) into each clone's `.claude/skills/godot-mcp-toolkit/`.
- **Skill delta = wave-2 medians − wave-1 medians** — a true apples-to-apples
  number on one surface, *not* a delta against the drifted run-1 rows.

Why two waves instead of a run-1 comparison: the surface deliberately cut token
cost since run 1 (`image_detail`, `mask=common` default, pagination caps) and
`script_edit` closed the exact gap behind run-1's Type-A median of 1 — a run-1
delta would credit those surface wins to the skill. Both waves are `parallel(3)`,
the certified mode; **never 6-way**. Clone *paths* are reused across waves (trust
flags key on absolute paths in `~/.claude.json`) and recreated fresh from source
between waves after harvesting.

> **Contrast with the extension arm.** 41q measures a **delta** (skill vs
> no-skill at the same HEAD), where variance needs medians — hence N=3 ×2. The
> extension arm is a **binary gate** with no baseline arm, hence N=1. State the
> asymmetry so N=1 there never reads as a shortcut.

## Gates

- **Tier-1 (hard, both waves):** regression checklist **20/20** not reoccurred ·
  **Type-A = 0** (with `script_edit` shipped, a nonzero Type-A is a real failure,
  not the known gap) · completeness **≥ the run-1 Sonnet floor**. Completeness is
  gated on the **method-consistent self-reported** measure (agent spec-table +
  orchestrator spot-check), and **additionally** an *inspected* Tier-3 number is
  recorded per leg (structural + console/runtime-error scan + screenshot sanity
  via the toolkit-as-instrument; winnability stays human-QA-only).
- **Tier-2 (banded delta):** confusion ratio, tokens (total + per-req), context
  pressure, cache-miss, reset-reactivate, Type-B. **The skill value IS the Tier-2
  delta** (expected direction: confusion ↓, tokens ↓, Type-B ↓). A
  wrong-direction move outside band = skill regression → triage (skill guidance
  vs toolkit behavior), fix the skill as **toolkit commit 2** (a new commit, never
  an amend), re-run the affected wave-2 legs.

## Extra checks

- **Two-instrumentation-rule prompt** — the frozen prompt carries exactly the two
  rules (MCP-tools-only + cache-miss recovery) and nothing else; no self-score,
  no task→group routing hints (that is what the skill provides — injecting it
  would collapse the delta). DX protocol §4.
- **Eager-manifest cross-check** — stamp the eager+meta count + sorted-name hash
  from `--list-eager` at the eval SHA, with a "Δ vs prior" note (41q expected
  **36**, `+script_edit`, vs run-1's 35).
- **Same-surface guardrail** — both waves run at the same product surface;
  preferred both after commit 1 at one SHA. A wave-1 finding that forces a product
  fix means landing it and re-running **both** waves at the new HEAD.
- **Model integrity** — measured build pinned to Sonnet; a stamped model whose
  family ≠ Sonnet voids the comparison (DX protocol §2/§7).

---

## Executed outcome (2026-07-21) — reference

Recorded here as the arm's first data point; the authoritative detail is the 41q
`## Outcome` section and the run dir
`Plan/ExecutionPlan/Validations/DXRuns/2026-07-21-9325bc8/report.md`.

- **Verdict: PASS both waves; the companion skill is a net DX improvement; no
  product regression.**
- **Surface:** toolkit `305695b` / server `9325bc8`, eager+meta **36**
  (`+script_edit`, hash `4675f6c0bf4e`), model `claude-sonnet-5`, both
  `parallel(3)`. Two rows in `DX-REGRESSION-RECORD.md` (rows 2 + 3, shared
  `[^41q]` footnote).
- **Skill delta (wave-2 − wave-1 medians, all expected direction):** calls **−55**,
  output tokens **−22,482** (121,336 → 98,854, −18.5%), tokens/req −1,606, cost
  −$4.22, duration −8 min. Confusion +0.005 and peak-tools +2 were within leg
  noise (≤0.12σ), not band breaks. **Type-A effective 0** and **Type-B effective 0**
  both waves.
- **Commits:** toolkit `305695b` (pre-eval audit + rewrite, `SKILL.md` 604 → 490
  via the `references/{type-wrappers,input-events,parallel-sessions}.md` split);
  server `9325bc8` (conditional product fix — `input_simulate` description aligned
  to implementation); toolkit `aa0deb1` (post-eval skill fix from DX finding F1,
  490 → 494).

## Last audit window SHA

The next toolkit-skill audit derives its delta window (shared ritual §1) starting
from the skill's last-touch commit. As of the 41q execution:

**Toolkit skill last touched:** `aa0deb1` (post-eval skill fix, 2026-07-21).
Bump this after each future toolkit-skill audit.
