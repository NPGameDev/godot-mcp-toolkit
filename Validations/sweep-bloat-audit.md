# MCP Tool-Sweep Bloat Audit

**Auditor:** read-only seat (independent analysis alongside a live sweep)
**Date:** 2026-06-29
**Scope:** `Validations/Sections/*.md` (30 files) + `Validations/tool-sweep.md`. `RESULTS.md` deliberately untouched.

## What "bloat" means here

A fixture or payload **larger than needed to exercise the behavior under test** — extra
bytes/items/magnitude that inflate a runner agent's context and wall-time **without adding a
distinct assertion**. The goal is byte-for-byte cheaper specs at identical coverage.

**Template (already fixed): 11.7.** The `save_read` paging test once told the runner to
`save_write` a **1000-char** string; **10 chars** exercise the identical multi-window pagination
contract (truncated → truncated → final page, hint on/off, clean EOF). Trimmed 1000B → 10B with
zero coverage loss. The spec even carries an inline "keep tiny on purpose" note now. This audit
hunts for the same shape: magnitude that buys no coverage.

## Headline

**The suite is already well-trimmed.** After reading every section, the 11.7 fix looks like it
was the dominant offender. The remaining candidates are small in absolute terms. Only **one** is a
clean 11.7-style analog (identical repeated items); the other two are low-impact judgment calls.
I am **not** padding the list with enum-coverage or cap-under-test payloads that only *look* big —
those are correct and noted below.

## Bloat candidates

| Section.Test | Issue | Current size | Proposed minimal | Coverage-safe rationale |
|---|---|---|---|---|
| **15.9** | `spriteframes_create` `run` animation lists **4 identical** `res://icon.svg` frames (and `idle` lists 2). The frames are byte-identical — extra copies only bump a count. | `idle`: 2 frames, `run`: 4 frames (**6** frame entries) | `idle`: 1 frame, `run`: 2 frames (**3** entries) | Assertion is "2 animations with **correct frame counts**". That needs (a) ≥2 animations and (b) two **distinct, independently verifiable** counts. Counts (1, 2) prove the per-animation count is recorded correctly and not swapped/shared, exactly as (2, 4) do. The 3 dropped frames are identical-texture duplicates that test nothing the count doesn't. Clean 11.7 analog. |
| **16.20** *(low / judgment)* | "All 8 presets quick check" re-creates `fire` and `rain` as **2D**, which 16.17 (`fire` 2D) and 16.18 (`rain` 2D) already covered. `sparks` here is 2D vs 16.19's 3D, so not a dup. | 8 GPUParticles2D nodes (2 redundant) | 6 nodes (drop `fire`,`rain`; keep `smoke,sparks,snow,explosion,magic,dust`) | Each preset is a distinct config path, so the *sweep itself* is legitimate enum coverage (same spirit as 28.9 shapes / 28.16 waveforms — see keep-list). Only `fire`/`rain` 2D are literal repeats of 16.17/16.18. **Trade-off:** dropping them sacrifices the "all 8 in one place" uniformity for 2 fewer node creates + cleanups. Lean toward keep; flagged for the orchestrator's call. |
| **3.20b** *(very low)* | `PackedVector2Array` round-trip uses a 3-point array. | 3 `Vector2` entries | 2 entries | The concern-053 target is "read-back is a **tagged dict**, not a `var_to_str` string". That String-vs-Dict distinction surfaces with ≥1 element; 2 keeps it visibly an array for the read==write compare. Trivial (~one short dict). Borderline — fine to leave as-is since 3 points is idiomatic. |

## Intentional / keep (size-is-the-point — considered and rejected)

- **28.9 (7 shapes), 28.16 (5 waveforms), 28.10 (4 colour formats), 28.5/28.4 region+radius** —
  exhaustive **enum / parser coverage**; each value is a distinct code path. A regression in one
  shape/waveform/format would only show here. Magnitude IS the coverage.
- **28.13 (4096×4096 → clamp ≤1024), 28.18 (duration 30 → clamp ≤5), 11.7.6 (`max_bytes`=100000 vs
  64 KB cap), 28.6 (`max_nodes`=1 truncation)** — the magnitude is the threshold under test.
- **Batch-rollup tests needing exactly 2 entries** — 2.15a, 3.14c/3.14d, 3.14b, 4.15/4.16, CS13.8,
  C9. Partial-failure / all-success rollup semantics require ≥1 success + ≥1 failure (or 2 successes
  for the additive-control). All already use the minimum of 2. C9's 3 instances each carry a
  *distinct* transform (translation / rotation / scale) — distinct coverage, not padding.
- **Crafted filter strings** — 7.5 `"SV2_SEED_Alpha42 test_line(parens)"`, 20.12
  `"SV2_RUNTIME_SEED_Beta99 check(braces)"`. The exact shape (digits for `\d+`, parens for
  literal-metacharacter matching) is load-bearing for the regex-vs-plain tests. Not shrinkable.
- **8.9 sparse layer map `{1,2,5}`** — the non-contiguous `5` exercises sparse-key handling; the
  gap is the point.
- **Fixture scripts whose every member is referenced** — 1.2 `actor.gd` (signal `hit`, exports
  `speed`/`label`, `get_info` all consumed by S3/S5/S6/S8/S20), 26-S1 LSP fixture (every symbol in
  the reference-position table is hit by a hover/definition/references test), 27-S1 debug target
  (lines 6/9 are breakpoint targets), 23 CS-S1 / CS14 C# (nested-dict marshalling needs the
  nesting). These are minimal-for-purpose, not bloat.
- **14.19 / C6 tilemap regions (`5×5`, `3×3`)** — a region is a compact `{x,y,width,height,...}`
  spec; `width:5` vs `width:2` is identical JSON/context cost (one extra digit, ~0 cells of
  wall-time difference). Not context bloat.

## Priority ranking (highest-impact trim first)

**15.9** (clean 11.7 analog, removes 3 identical inline frames) → **16.20** (optional 2-preset dedup,
trades enum-sweep uniformity — orchestrator's call) → **3.20b** (trivial 3→2 points; safe to skip).

---

*Notes / uncertainty:* This set is lean; I deliberately did **not** inflate the count with
enum-coverage or cap payloads. If only one trim is applied, make it 15.9. 16.20 is the only place
I'm genuinely split — it is simultaneously legitimate enum coverage *and* carries 2 literal
duplicates of earlier tests; I leaned keep. No large repeated literal payloads, no oversized
byte/line-window reads, and no megabyte fixtures were found anywhere in the suite.
