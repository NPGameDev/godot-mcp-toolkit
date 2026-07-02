---
status: accepted
---

# 0014 — headless-DX response shape (`is_headless`-gated guidance)

## Context

Under `--headless --editor` the plugin loads and the vast majority of tools behave identically to a
display editor, but a handful **silently degrade** rather than guiding the caller:

- `game.start` returned `success:true, runtime_ready:false` even though the game process cannot launch
  without a display, so Mode B (the runtime WebSocket) never connects — a **false-success** (nothing
  stays playing).
- `editor_get_console` returned `count:0` for an editor parse-error capture — reads like "no matches"
  rather than "a headless editor doesn't revalidate scripts, so parse errors aren't captured here."
- `node_call_method` returned `INVALID_METHOD` on a reloaded node's freshly-added method on **4.4+
  headless** — reads like a bug, not "a headless editor never re-instantiates the live node."

A full-suite headless probe (41n-quater, Godot 4.5) found **15 of 531** checks failing this way, and
41n-quater shipped CI workarounds (`smoke --skip 10,14`, `flows --skip 2`) to stay green.
`editor.screenshot` was already the **exemplar** — an early `is_headless()` guard returning
`HEADLESS_UNSUPPORTED` + "requires a display server."

The real defect is **misleading, not non-deterministic**: the degraded responses were already
deterministic; what they lacked was **honesty** — a code and/or a hint telling an LLM (or a CI job)
*why* the tool is degraded and *what to do instead*. See the plan-repo iteration
`41n-quater-bis-headless-dx-determinism.md` and `Insights/stale-live-instance-method-hazard.md`.

## Decision

**Bring every headless-divergent tool up to the `editor.screenshot` bar** — a deterministic,
self-explaining response — under one controlling invariant, plus a wire signal that lets the server
branch its headless assertions.

1. **Per-tool guidance (each an early guard / gated branch):**
   - `game.start` — early `is_headless()` guard returns **`HEADLESS_UNSUPPORTED`** (the existing code,
     reused — not a new one) with a redirect to `script_check` / scene inspection / `editor_get_console`.
   - `editor_get_console` — an **additive `headless_hint`** attached whenever error capture is requested
     (`level_filter` includes `"error"` OR a `text_filter` is set), **regardless of match count**,
     steering to `script_check`. Buffer/file capture mechanics are untouched.
   - `node_call_method` — the existing reactive stale-instance hint is **widened to also fire on 4.4+
     headless** (a display editor hot-reloads, so `has_method` would already be true; a headless editor
     never re-instantiates the reloaded node), with a headless-specific message distinct from the
     `< 4.4` engine-cache wording.
   - `editor.screenshot` — the exemplar guard is enriched with a **headless-accurate** redirect
     (`script_check` primary; `editor_get_console` = runtime output only, since its own parse-capture is
     headless-degraded).

2. **Controlling invariant — `is_headless`-gated, display path byte-identical.** Every headless-divergent
   branch is gated on `is_headless()` (`DisplayServer.get_name() == "headless"`, via
   `Modules.VersionUtils.is_headless()`). No headless workaround may alter a display response. Each fix
   is an **early guard or a gated branch, never a refactor of the shared display path** (see "the
   deliberate deviation" below).

3. **Server-side signal — the handshake `headless` field.** The Mode-A auth ack (`_build_auth_ack`)
   carries `"headless": is_headless()` alongside `godot_version`, so the bridge exposes
   `bridge.isHeadless()` and the smoke/flows suites branch their headless assertions off the **wire
   signal** instead of a per-suite `editor.screenshot` probe. The runtime autoload's bare
   `{authed:true}` is unchanged. The field is additive and follows the `godot_version` precedent — it
   gets a contract-ledger entry + a `data-verified` bump, **not** a standalone ADR; this policy ADR
   records it.

### The deliberate deviation — why the guards stay scattered

A future contributor could reasonably want to **unify the scattered `is_headless()` early guards into a
shared helper on the common path**. That is **deliberately not done here.** The display responses are
byte-identical and battle-tested by the full smoke + flows suites; a shared-path refactor risks
perturbing them for no behavioral gain. Keeping each guard **local to its tool** makes the display path
*provably* untouched (grep for `is_headless(` shows every divergence at its call site). This ADR exists
so that locality is read as intentional, not as duplication to be "cleaned up."

## Consequences

- An LLM (or CI) running headless gets deterministic, actionable guidance from every divergent tool
  instead of a false-success, an empty result, or a bare error that reads like a bug.
- The 41n-quater `smoke --skip 10,14` / `flows --skip 2` workarounds are removed; the full suite runs
  headless, asserting the new deterministic responses (including the positive `headless_hint` proof).
- Display behavior is unchanged — the gated branches never fire on a display editor.
- The pure `StaleInstanceHint` decision gains a `headless` parameter and is unit-tested **editor-free**
  across the (headless × version) axis; the reactive caller feeds it `Modules.VersionUtils.is_headless()`.
- The handshake gains one additive boolean; `bridge.isHeadless()` is `undefined` pre-auth (mirroring
  `getGodotVersion()`), never a defaulted `false` that would falsely claim "display."

## Considered and rejected

- **Make Mode-B playtest work headless** (spawn a `--headless` child game so the runtime WS binds). The
  runtime autoload is display-agnostic (`mcp_runtime_server.gd` gates only editor / `--check-only` /
  `!has_feature("editor")`), so this is likely feasible — but the blocker is the **upstream editor play
  path**, not the toolkit. Filed PostRelease **[High]**
  (`Plan/Ideas/PostRelease/2026-07-02-headless-mode-b-playtest.md`). Until then, deterministic-unavailable
  is the honest response.
- **Make headless hot-reload actually re-instantiate (4.4+).** Likely async-scan / idle timing, not an
  architectural block, but it must prove reliably green (10/10 on 4.4–4.7, both editors) before it could
  gate CI. Filed PostRelease **[High]**
  (`Plan/Ideas/PostRelease/2026-07-03-headless-hot-reload-reinstantiation.md`). Until then, the stale hint
  is the honest response.
- **A headless re-emit affordance so editor parse errors ARE captured** (force `filesystem.update_file` →
  capture via the 4.5+ `OS.add_logger` sink). Engine proposal #13479 blocks `source="file"` forever, so
  this is the only future path to *add* headless capture — but it is its own design. Filed PostRelease
  **[Low]** (`Plan/Ideas/PostRelease/2026-07-03-headless-editor-parse-capture-reemit.md`). Until then,
  `headless_hint` steers to `script_check`.
- **A dedicated new error code for headless-unsupported playtest.** Rejected: `HEADLESS_UNSUPPORTED`
  already exists and is the exemplar; reusing it keeps the code vocabulary tight (one code per condition).
- **Unify the guards on the shared path.** Rejected — see "the deliberate deviation" above.
