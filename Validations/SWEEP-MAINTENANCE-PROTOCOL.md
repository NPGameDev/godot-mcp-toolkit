# Tool Sweep Maintenance Protocol

## Last Known Good SHA

The sweep currently covers all behavior up to and including:

**Toolkit repo:** `dec5b24` (feat(plugin): editor-side runtime log cache for post-crash debugger_get_log)
**Date:** 2026-05-16

When updating the sweep, run `git log --oneline <this SHA>..HEAD` to find commits that need new test coverage. After updating, bump this SHA to the latest commit included.

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
