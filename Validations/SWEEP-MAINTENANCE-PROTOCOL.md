# Tool Sweep Maintenance Protocol

## Last Known Good SHA

The sweep currently covers all behavior up to and including:

**Toolkit repo:** `ffe7a13` (test(toolkit): add headless unit test infrastructure)
**Date:** 2026-05-24

When updating the sweep, run `git log --oneline <this SHA>..HEAD` to find commits that need new test coverage. After updating, bump this SHA to the latest commit included.

## Relationship to the server flow suite (added 41m-bis)

This **sweep** is the **LLM-driven** validation layer (hint/UX quality,
exploratory edge-discovery). Its deterministic counterpart is the server repo's
**flow suite** (`godot-mcp-server` → `test/flows/`, run via `npm run flows`),
which scripts the **cross-tool, stateful flows** that *are* deterministic —
extension lifecycle (this sweep's Section 24), combo chains (Section 22), and the
flow-shaped regression-watch items. The two are complementary, not redundant:
the flow suite is the fast, ~0-token pre-refactor regression baseline; this sweep
keeps the non-deterministic work **and confirms flow-suite failures** — when
`npm run flows` reports a FAILED flow/step, re-run *this sweep* targeted at that
one flow to classify **stale script** (update the test) vs **real regression**
(fix the code). The word "sweep" is reserved for this LLM layer; the
deterministic `.ts` layer is the **flow suite** (see the server repo's
`test/SMOKE-COVERAGE-MANIFEST.md` → "Flow Suite", and plan-repo `CONTEXT.md` →
"Validation vocabulary"). New tools/params → update **sweep + smoke + flows**.

## Agent-drivability principle

**Every sweep section must be agent-drivable in its applicable environment.** The
sweep is the **LLM-driven** layer: each step is exercised end-to-end by an agent
calling MCP tools. A step that cannot actually be run shouldn't sit in a
content-map masquerading as coverage — it inflates the count and lulls a reviewer
into thinking a behavior is tested when nothing exercises it.

When a step looks un-runnable, classify it honestly into one of two buckets:

- **(a) Un-runnable *anywhere* by the agent** — e.g. config-only knobs the agent
  can't (and *shouldn't*) set, or behaviors with no agent-reachable fixture.
  → **Make it drivable** by spelling out concrete setup with real MCP tools that
  *provisions* the precondition (e.g. register a temp autoload via
  `autoload_manage` before `game_start`; launch a breakpoint-free scene to force
  `NOT_BREAKED`). If it genuinely can't be driven from the sweep, **remove it**
  and cover the behavior in the layer that *can* — typically server smoke
  (`test/sections/*.ts`) — and leave a one-line cross-reference here naming the
  owning layer. Do **not** leave a dead step in place.
  - *Example:* the `save_read_cap_kb` cap is config, not an agent-settable param,
    so it was removed from §11 and is owned by smoke `21_response_caps.ts` (§21).

- **(b) Legitimately env-gated** — runnable in a *specific legitimate environment*
  the dogfood project isn't, e.g. the C# section (needs a .NET project + Mono
  editor). → **Keep it.** It is real coverage, just gated. Annotate the section
  with its required environment and an **expected-SKIP** elsewhere so a skip on the
  default project reads as the gate working, not a failure.
  - *Example:* §S23 (C#) is C#/.NET-only; expected-SKIP on the GDScript dogfood.

The distinction matters: bucket (a) is a **coverage bug** (fix or relocate);
bucket (b) is **correct design** (keep + gate). Never silently downgrade a (a)
into a perpetual SKIP — that hides the gap.

## When to update the sweep

Update the tool sweep (`Validations/tool-sweep.md` + relevant `Sections/*.md`) whenever an iteration:

1. **Adds a new tool** — add individual test cases (happy path + guards) to the appropriate section file. Add at least one combo chain exercising the new tool with existing tools.
2. **Adds new parameters** to an existing tool — add test cases exercising the new parameter in the section where that tool is tested.
3. **Changes a guard or error message** — update the expected result in the relevant test case. If the guard is new, add a guard test.
4. **Improves a DX hint** — add a REGRESSION WATCH annotation at the relevant test case noting the expected hint content.
5. **Fixes a bug** — add a test case that would have caught the bug, with a REGRESSION WATCH annotation including the fix commit SHA.
6. **Renames a parameter** — update all test cases using the old name in the affected section file.
7. **Removes a tool** — remove the test cases from the section file and update the coverage manifest.

## How to update

1. Identify the appropriate section file in `Validations/Sections/`.
2. Add test cases following the existing numbering (Section.TestNumber format).
3. If adding a REGRESSION WATCH, include the fix commit SHA for traceability.
4. Update `Validations/SWEEP-COVERAGE-MANIFEST.md` to reflect new test numbers.
5. Update the tool-sweep.md index if test counts changed.
6. **Bump the Last Known Good SHA** at the top of this file to the latest toolkit commit included in the sweep. This is mandatory — without it, future agents won't know where to start their gap analysis.

## Section file structure

Each section file follows this format:
```markdown
# Section N — Title

**Dependencies:** [which sections must run first]
**Tools tested:** [tool names]
**Tests:** [count]

---

[Test cases with REGRESSION WATCH annotations inline]

---

## Cleanup

[Per-section cleanup steps]
```

## Coverage manifest maintenance

After any sweep update, update `Validations/SWEEP-COVERAGE-MANIFEST.md`:
- Add new tools with their test numbers
- Update test numbers if reordered
- Mark any new gaps identified

## Verification

After updating the sweep:
- Run at least the modified section to verify new test cases pass
- A full sweep is required only at milestone gates (41k-ter-et-tricies, 41l-duodecies, 41o-bis)

## Adding new sections

If a new tool domain is added (e.g., a new category of 3+ tools):
1. Create a new `Sections/NN-topic.md` file
2. Add it to the Section Map in `tool-sweep.md`
3. Define dependencies clearly
4. Include per-section cleanup
5. Use `sv2_` artifact prefix to avoid collision
