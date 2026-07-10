# Paginating tools return a self-describing offset envelope, built through one shared class

Before 1.0 the read/cap tools accreted incompatible response shapes. Ledger #9
(2026-06-29) harmonized them onto a `truncated` flag + canonical `total_<unit>`,
but it propagated the incumbent `truncated` name without weighing it against the
industry-convergent `has_more`. `41o-nonies-bis` then reshaped `scene_query` into a
researched self-describing envelope — echoing its own paging state, `has_more` not
`truncated`, `returned` not the ambiguous `count`, exact totals from a walk-all —
and left the remaining tools split. This ADR ratifies that envelope as the standard
across every paginating tool and records why.

An opaque cursor (MCP `nextCursor` / Stripe-token style) was considered and
rejected for tool payloads. MCP's opaque-cursor mandate governs *protocol lists*
(`tools/list`, `resources/list`), not `tools/call` results, which are free-form
content — so an integer offset is spec-compliant here. And an integer is strictly
more legible to an LLM: it can reason "returned 50 of 1240" and self-correct, and
an offset makes an exact total naturally available. Cursors only win at huge scale
under heavy concurrent mutation — not editor-side data.

## Decision

**A self-describing offset envelope, expressed as a 2-axis model and built through
one shared `Pagination` class.**

- **Envelope invariants (every paginating/capping tool):** `has_more` (bool),
  `total_<unit>` (exact, walk-all), `returned` (this page's size) — always present.
  `has_more` replaces `truncated`; `returned` replaces `count`. The `<unit>` noun
  specializes (`total_matches`/`total_classes`/`total_bytes`/`total_lines`) — an
  explicit unit is a legibility feature, and the uniform structure is the win.
- **Resume mechanism (a per-tool property, the second axis):** either a **linear
  resume field** — the integer `next_offset` / `next_start_line`, emitted when
  `has_more` — or, for tools whose walk is not linearly resumable, a **documented
  non-linear navigation** via a scoping parameter, with **no** resume field. The
  integer resume field is deliberately NOT called a "cursor" (that term is reserved
  for the rejected opaque token).
- **Four families** specialize the unit + echo shape: LIST (index), CONTENT-byte
  (`save.read`), CONTENT-line (`script.read`, log readers), and SPATIAL
  (`scene.spatial_map`, `tilemap.read_cells` — navigate by `region` + the `bounds`
  extent).
- **Clamp, don't reject.** A caller window param over the tool's max is clamped to
  the max and disclosed in-band (`limit_clamped: true` + a clause appended to
  `hint`), never silently and never as an error; a genuinely-invalid value
  (`≤ 0` / non-int) is rejected. The max value is per-tool (the unit differs).
- **One builder, one contract.** Every toolkit emitter routes through
  `Modules.Pagination` (`contract/pagination.gd`); the server is REFLECT (forwards
  `message.result` verbatim) and has no response builder. This makes the contract
  shared in code, not just prose — a new paginating tool calls the class and
  inherits the shape.

## Cursor-less tools are resume-field exceptions, not envelope exceptions

`asset.list` / `asset.get_dependencies` (a depth-first filesystem walk) and the
spatial tools (2D/3D grids) have no meaningful linear order, so they omit the
resume field. They still emit every invariant (`has_more` + `total_<unit>` +
`returned`) and navigate by a scoping param — `path_prefix` + filters for the asset
walk, `region` + the `bounds` extent for spatial — named in the `hint` so an agent
stays inside the toolset. Making the asset walk linearly resumable (the
`scene_query` treatment) is a viable future upgrade, deferred until friction
evidence appears.

## Consequences

- One learnable envelope: an agent that learns the shape on one tool reads every
  other paginating tool with no surprise; `has_more`/`returned` match what the model
  saw most in training.
- Exact totals cost a walk-all past the page; editor-side data is bounded, so this
  is affordable and worth the legibility.
- The shared class centralizes the required-field guarantee — a tool cannot ship a
  half-formed envelope — at the cost of one indirection per emitter.
- Pre-1.0 clean break (no shim); the breaking renames are recorded in the
  contract-change ledger, superseding #9's `truncated` naming.
