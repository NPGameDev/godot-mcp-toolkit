# Folder tools take a bare `path` param, end to end

The `folder_create` / `folder_delete` tools advertise, transport, and handle a
single filesystem argument named **`path`** — the same name in the server's
advertised schema, on the wire (`folder.create({ path })`,
`folder.delete({ path, recursive })`), and in the toolkit handler. There is no
alias and no advertised-vs-wire divergence.

## Context

A DX regression run (2026-07-13) caught the model sending `path` to
`folder_create` eight times — every attempt a `-32602` "expected string,
received undefined" — before it adapted to the then-required `folder_path`.
Those two tools were the only ones in the run to trip param validation. On a
surface where ~40 tools use the idiomatic `file_path` (produced correctly 60+
times, zero failures), the model "corrects" the outlier `folder_path` to the
generic `path`.

`folder_path` had itself been a deliberate rename *from* `path` (2026-04-17),
made when bare `path` was ambiguous across node-tree, file, and folder meanings.
That ambiguity no longer holds: every sibling path param is now prefixed
(`file_path`, `node_path`, `parent_path`, `source_path`/`dest_path`), so `path`
is unique to these two tools, and the tool name (`folder_*`) already says the
path is a folder. Renaming back is safe *because* of that uniqueness — `path`
disambiguates on its own here.

## Decision

**Rename `folder_path` → `path` everywhere for `folder_create` and
`folder_delete`; no alias, no shim.**

- **One name, all layers.** The advertised `inputSchema`, the wire method
  payload, and the toolkit handler all use `path`. `folder_delete` keeps its
  `recursive` param unchanged.
- **`path` stays required** in the advertised schema (a raw `{ path: z.string() }`
  shape), with no `additionalProperties` looseness.
- **Scoped to single-path folder tools only.** Multi-path tools keep
  role-distinct names (`asset_import`'s `source_path`/`dest_path` are not
  renamed — `path` there would be ambiguous). Node-tree paths (`node_path`,
  `parent_path`) are never renamed to `path` — that collides with the filesystem
  meaning.

## Considered options

An earlier draft of this decision advertised `path` while keeping `folder_path`
on the wire, resolving the two names with a server-side `z.preprocess` rename —
a "hidden alias" that would accept either name. **That mechanism is infeasible
on the current stack** (MCP SDK 1.29 / zod 4): a top-level `z.preprocess`
(a Zod *pipe*) loses its object shape when the SDK converts it for `tools/list`,
so the advertised schema comes out **empty** — no `path` property, no `required`
— and the structural smoke gate fails Zod→JSON-Schema conversion at two checks.
A builder and an independent adversarial refuter both reproduced this against
the real registration path; no full-`ZodType` form survives it. The hidden-alias
approach was therefore abandoned.

Given the choice between a server-only shim and a clean rename, the full rename
was chosen for cross-layer consistency: a reader tracing the wire sees the same
name the model sees, with no advertised-vs-wire divergence to explain.

The belt-and-suspenders coverage the alias would have bought (silently accepting
a stray `folder_path`) is low-cost to drop: the raw shape strips the unknown key
and the resulting error names the correct, advertised param (`path`), which is
now what the model reaches for anyway.

## Consequences

- **No advertised-vs-wire divergence.** The name is identical at every layer.
- **A stray `folder_path` now errors** (naming `path`), where the abandoned
  alias would have accepted it. Acceptable — the run-1 evidence is that the model
  reaches for `path`, not `folder_path`.
- **Pattern for the deferred alias candidates changes.** Any future
  reflex-name friction (evidence-gated) is resolved by a rename to the reflex
  name, provided that name is unambiguous on the surface — not by a server-side
  alias.
- **No `contract.md` / arch-doc change.** The wire contract does not enumerate
  per-tool params (they live in the generated tool-reference), and a param
  rename is not an architectural change — the blast radius is the two folder
  tools plus their tests.
