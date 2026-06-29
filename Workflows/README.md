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
