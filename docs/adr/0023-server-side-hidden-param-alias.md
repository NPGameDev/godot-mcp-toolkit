# A reflex-name param is advertised while the wire keeps its canonical name, aliased server-side

DX regression run 1 (2026-07-13) caught the LLM sending `path` to `folder_create`
**8 times** (every attempt a `-32602` "expected string, received undefined") before
it adapted to the required `folder_path`. `folder_create`/`folder_delete` were the
*only* tools to trip param validation in the whole run: `folder_path` is the anomaly
on a surface where ~40 tools use the idiomatic `file_path` (produced correctly 60+
times, zero failures), so the model "corrects" the outlier to the generic `path`.
This ADR ratifies how we close that gap — an **LLM-facing param alias** — and records
why the fix lives entirely in the server and why the advertised name may differ from
the name on the wire. Scoped today to `folder_create`/`folder_delete`; it is the
pattern the deferred, evidence-gated alias sweep (`asset_import`, `save_*`, …) will
follow. Full trail: `Plan/Reference/GrillingSessions/2026-07-13-dx-run1-design-fixes.md`
and iter `41o-quater-bis`.

## Decision

**Advertise the reflex name to the LLM; keep the descriptive name on the wire;
resolve the alias in the server before validation.**

- **Advertised param = the reflex name.** `folder_create`/`folder_delete` advertise
  **`path`** (what the model reaches for). `folder_path` becomes a **hidden alias** —
  accepted, **never** in the advertised `inputSchema` / `tools/list`.
- **Alias semantics.** The required slot is satisfied by **either** name; if **both**
  are sent the **advertised (official) `path` wins**; if **neither**, the error names
  the **advertised** param (never the alias).
- **Single-path tools only.** A tool with one filesystem path may alias to `path`;
  multi-path tools keep role-distinct names (`asset_import`'s `source_path`/`dest_path`
  are **not** aliased — `path` there would be ambiguous). Node-tree paths
  (`node_path`, `parent_path`) are never aliased to `path` — that collides with the
  filesystem meaning.
- **Resolved server-side; the wire is unchanged.** A `z.preprocess` renames a stray
  `folder_path`→`path` *before* the object schema validates, so the advertised schema
  stays `{ properties:{path}, required:[path] }` (alias hidden, no `additionalProperties`
  looseness). After validation the tool handler maps `path`→`folder_path` at the wire
  boundary: the wire method stays `folder.create({ folder_path })` and the **toolkit
  handler is untouched**. The alias is a pure LLM-ergonomics concern and lives only in
  the LLM-facing layer.

Terms are pinned in the plan-repo `CONTEXT.md` *Param-alias vocabulary* (**advertised
param** / **hidden alias** / **canonical wire param**).

## Considered options

The server catalogue's zod **strips** undeclared top-level params (verified; see
`docs/dev/contract.md` C8), so an undeclared alias never reaches the handler — the
alias must be handled inside the schema. Four shapes were weighed:

- **Rename-only (advertise `path`, drop `folder_path`).** Cleanest schema, but a model
  that reflexively sends `folder_path` (plausible — the tools are *named* `folder_*`)
  would newly fail where it succeeds today. Rejected: gives up cheap belt-and-suspenders
  coverage.
- **`path` optional + `.passthrough()`.** Lets `folder_path` ride through, but forces
  the advertised `path` to be **optional** (the "≥1 of two" rule can't mark it required
  in zod) plus `additionalProperties:true` — a looser, less-guiding schema, self-defeating
  for a DX fix. Rejected.
- **Declare both params visibly.** Simple, but shows two names for one path — exactly the
  confusion the alias is meant to remove. Violates "hidden." Rejected.
- **`z.preprocess` rename (chosen).** Keeps `path` **required** in the advertised schema
  *and* accepts `folder_path`, with no looseness. Verified: `path`-only ✓; `folder_path`-only
  → `{path}` ✓; both → `path` wins ✓; neither → error names `path` ✓.

Resolving in the **toolkit** instead of the server was also rejected: it would push an
LLM-ergonomics concern into the executor, churn the toolkit handler + wire contract for a
pure-naming change, and set the wrong precedent for the sweep. Aliases belong at the server
(LLM-facing) boundary.

## Consequences

- **Advertised name ≠ wire name is intentional.** A reader tracing the wire sees
  `folder.create({ folder_path })` for a tool whose schema advertises `path`. That divergence
  is deliberate — the alias is resolved before the wire — not a bug.
- **Pattern, not a one-off.** The deferred alias candidates inherit these exact semantics
  (advertise reflex / hidden alias / official-wins / error-names-official / single-path-only /
  server-resolved). Promote them only on new friction evidence, not speculatively.
- **Full-ZodType `inputSchema` caveat.** Aliased tools use a full `z.preprocess(...)` schema
  rather than a raw shape; confirm the registration pipeline (`addStringCoercion`,
  `registerToolWrapped`) tolerates it. Proven end-to-end by a live `folder_create({ folder_path })`
  smoke call, not a unit test alone.
- **No `contract.md` / arch-doc change.** The wire contract does not enumerate per-tool params
  (they live in the generated tool-reference), and a param alias is not an architectural change —
  the blast radius is server-local.
