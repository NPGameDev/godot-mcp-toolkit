# Workflows/ — godot-mcp-toolkit orchestration memory

Content map for the `workflow-orchestrator` skill. Read at run start; drill into
an individual spec only when its area is in play.

## Specs
- [tool-sweep-delegation.md](tool-sweep-delegation.md) — running the MCP tool
  sweep (`Validations/`) via delegated per-section `opus` builder agents.

## Hard rules (distilled — see the spec for detail + the full brief template)
- **Section-runner agents get NO shell.** Background agents hang on Bash/`node`
  permission prompts (a fixture-generating `node -e` stalled two runs). Construct
  any test data inline; the agent uses MCP tools + Read/Edit ONLY.
- **Briefs are 100% self-contained.** Embed the console-isolation protocol, the
  section's tests verbatim, the tool schemas, the RESULTS row anchor + format,
  sweep meta, and caveats. Tell the agent *"everything you need is in this brief;
  do not look anything up."* Its ONLY file Read is `RESULTS.md`.
- **Tiny fixtures.** Pagination / byte-paging tests use ~10 bytes, never
  hundreds/thousands. Large inline content bloats context and slows the sweep
  with zero added coverage. (S11 spec already trimmed 1000B→10B.)
- **Small MCP batches (2–3 calls/message).** 7+ calls in one message stalls the
  client UI on the last call even though the server completes them.
- **Sequential only.** One shared Godot editor + one `RESULTS.md` ⇒ never
  parallel. One section-agent in flight at a time.
- **Orchestrator pre-activates the section's tool group** (`discover_tools`)
  before spawning; keep `cleanup`/`resource_io`/`editor_advanced`/`asset_ops`
  active across the run, reset only section-specific groups. The agent only
  `ToolSearch`-selects schemas by full `mcp__godot-mcp-toolkit__` names.
- **Tier = `sonnet`** for section-runners (lowered from opus 2026-06-29, user
  call). The fully self-contained briefs reduce the work to execute + judge
  against explicit Expect lines + spelled-out contracts/watches — Sonnet handles
  that, ~40% cheaper on output. The `opus` orchestrator is the judgment backstop
  (reviews every report; escalates a genuinely subtle section back to opus).
  **Caveat:** subtle regression-recognition must happen AT the agent (the
  orchestrator only sees summaries), so keep briefs explicit about every contract
  to check. Escalate to opus when correctness hinges on multi-step reasoning the
  brief can't pre-specify — e.g. **S22 combo chains** (tool-interaction bugs).
  Orchestrator stays lean: reviews ≤30-line reports, never reads section files.

## Sweep facts (41n-ter Pass-3, this project)
- MCP server `godot-mcp-toolkit` on **port 6550**. Project is GDScript (0 C#).
- **S23 (C#) → SKIP.** **S24 (Extensions) → no editor restart needed on 4.5**
  (the restart requirement is a 4.2-only issue).
- `RESULTS.md`'s per-section row table IS the durable resume tracker — do NOT
  spin up a parallel TaskCreate tracker.
- New deviations route to **41n-ter-bis** (flag, don't fix in place).

## Sweep facts (41n-octies P3, Godot 4.7 — 2026-07-03 run)
- **Godot 4.7 clean.** All tool groups work; **all 6 prior-run (41n-ter) FAILs RESOLVED** (S12.6/12.7 classdb pagination edge, S25 UR1.6/UR2.2 undo redo+rename, S26.15 completion default-limit, S26.10 shader-symbols now documented-correct). Sole FAIL: **S6.6** script_check diagnostics lack line/column (generic line:0 stub — Minor). New deviations route to **41n-octies-bis**.
- **scene_create now HONORS `root_name`** (root = given name; filename stem only as fallback when omitted). The S1 §1.8 spec note ("root_name ignored") is STALE — S17.1/17.1b already corrected. Confirmed S1/S2/S17/S22-C5.
- **MID-SECTION TOOL ACTIVATION IS UNCALLABLE BY THE SECTION SUBAGENT** (its ToolSearch deferred-index is frozen at spawn — confirmed 41n-octies S24 extension commands + S28 `placeholders` group). Two fixes: (a) if the subagent must CALL an on-demand group's tools, the ORCHESTRATOR **pre-activates that group BEFORE spawning** (a section test that re-activates it just sees `already_loaded`); (b) for genuinely-dynamic tools — extension commands registered by `extensions_refresh` mid-section (S24 E3/E10a-d), or a group the section's OWN test activates (S28/28.8 texture_generate+sound_generate) — the subagent CANNOT call them; the ORCHESTRATOR runs those call-path tests **inline in its interactive session** (which DOES absorb mid-session `tools/list_changed`) and edits the row. Recovered S24 E3/E10a-d + S28 28.9-28.19 this way.
- **RESULTS-append backslash trap:** rows containing regex `\d` (S7, S20) collapse `\\`→`\` on Read, breaking the next agent's full-row Edit anchor — tell agents to anchor on a **backslash-free substring at the row START** (e.g. `| SN — Title | t | p | f | s |`).
- **Prior RESULTS notes ≠ current section specs** for exact paths/params (the scaffolding scene was renamed main.tscn→Sv2Main.tscn since 41n-ter). Trust the current `Sections/NN-*.md`, not prior RESULTS rows.
