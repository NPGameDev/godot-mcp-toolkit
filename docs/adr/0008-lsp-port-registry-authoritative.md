# GDScript LSP port discovery is registry-authoritative

> **Amended by [ADR 0025](0025-lsp-claimant-liveness-corroboration.md) —
> 2026-07-25.** The registry stays authoritative and the detection stays
> server-side; the `process.kill(pid, 0)` liveness test below is now corroborated
> against the claimant's own WebSocket port, because a recycled PID resurrected a
> dead editor as a live claimant.

Godot's GDScript Language Server binds a **single machine-wide** TCP port
(default `6005`) taken from the editor setting
`network/language_server/remote_port` or the per-launch `--lsp-port` flag — there
is no per-project LSP port, and no engine API to read the bound port/host or
whether the bind even succeeded (verified against engine source 4.2–4.7;
`Insights/lsp-multi-instance-port-analysis.md`). When a second editor opens it
cannot bind 6005, and on **4.2–4.6** its LSP **fails silently**
(`gdscript_language_server.cpp` — no `else` on the `listen()` path). **Godot 4.7**
added a failure branch (`--- Failed to start GDScript language server on port N:
<error> ---`), so a human watching the Output dock does see it — but we still
cannot: `EditorLog::add_message` never routes through `print_line` or the logger
chain, so that line reaches neither stdout nor `user://logs/*.log`. On every
supported version the bind failure is unreadable from GDScript, which is why the
registry stays authoritative. The `lsp_*` tools live in the server and
previously connected to a fixed `127.0.0.1:6005`, so they always reached the
**first** editor — returning wrong-project results for any second editor (a
worktree *or* a different project) with no error: the cardinal failure (silently
wrong, not visibly unavailable).

Every other tool already routes through the toolkit's per-project WebSocket (each
editor claims a free port in 6550–6560 and publishes it to the `projects.json`
registry the server resolves by path). This ADR brings the LSP into that model.

**Decision: the editor plugin publishes its setting-derived LSP endpoint into the
per-project registry entry; the server discovers it per project and treats a
registry hit as authoritative; collisions are detected server-side and surfaced
visibly (`LSP_PORT_CONFLICT` / `LSP_UNAVAILABLE`), never as a silent fallback.**

- **Shared-vs-unique-port asymmetry — no blind 6005 fallback.** The WebSocket
  transport may fall back to its base port (6550) on a registry miss because WS
  ports are **unique per editor** — a blind WS fallback can only ever reach the
  one editor that owns that port. The LSP port is **shared** (machine-wide 6005),
  so a blind LSP fallback would reach whichever editor grabbed 6005 first — the
  exact wrong-project bug. The server therefore falls back to 6005 **only when no
  live editor holds it** (`liveLspClaimants(6005)` empty); otherwise it fails
  visibly. This single asymmetry is the heart of the decision.
- **Detection is server-side.** The plugin cannot read whether its own LSP bind
  won (no engine API), and the toolkit's liveness check
  (`OS.is_process_running`) false-negatives for live siblings on Windows. The
  server uses `process.kill(pid, 0)` — reliable on Windows — over the registry's
  live claimants and connects only if it is the **strictly earliest** `started_at`
  claimant of the port (first-to-`listen` wins, matching the engine). A
  same-second tie fails *both* sides rather than risk one returning wrong data.
- **Root-verification guard (4.5+).** On connect the server sends its project's
  real `rootUri` in `initialize` and watches for the LSP's `window/showMessage`
  workspace-root-mismatch warning (Godot PR #104401, **4.5+**; match substring
  `"might not work correctly with other projects"`). If it fires, the server
  reached the wrong editor → disconnect + `LSP_PORT_CONFLICT`. This closes the
  near-simultaneous-tie hole **and** catches a holder that isn't in our registry
  at all (a plain editor or another tool on 6005) — which the registry check
  structurally cannot see.
- **`--lsp-port` rides an env var, not the registry.** The engine consumes
  `--lsp-port` before it reaches `OS.get_cmdline_args()` and never writes it to
  the setting, so the plugin can publish only the **setting-derived** port. A
  multi-instance LSP setup therefore pairs `--lsp-port <n>` (launch) with
  `GODOT_MCP_LSP_PORT=<n>` (server override). We deliberately do **not** seed
  `GODOT_MCP_LSP_PORT` into the `.mcp.json` template: an env override bypasses
  conflict detection, re-creating the silent bug.

## 4.2–4.4 limitation

The root-mismatch warning (the second detection layer) ships only in Godot 4.5+.
On 4.2–4.4 the server cannot detect a foreign or near-simultaneous holder of port
6005, so a multi-editor LSP setup must **always** use a distinct `--lsp-port` +
`GODOT_MCP_LSP_PORT`. Documented in `docs/multi-instance.md` and
`COMPATIBILITY.md`.

## Considered alternatives

- **Blind 6005 fallback on a registry miss (the status quo of every comparable
  tool).** Rejected — it is precisely the silent wrong-project failure this ADR
  exists to prevent. A miss is a *visible* failure.
- **Toolkit-side conflict detection (publish an `lsp_conflict` flag).** Rejected
  as the authority: `OS.is_process_running` is unreliable on Windows and the
  plugin can't see a non-registry holder. The toolkit publishes **facts only**
  (host/port); the dock shows a *best-effort* indicator, but the server is the
  authority. Detection that prevents wrong data must be server-side.
- **Tier-2 auto-move (the toolkit moves a colliding editor's LSP to a free port
  via the editor setting, for zero-config multi-instance).** Rejected for 1.0: it
  mutates a machine-wide, per-user editor setting that must stay moved all
  session, with a crash/concurrency leak window that silently breaks third-party
  LSP clients (nvim @6005, VS Code godot-tools @6008) we don't own — high-harm,
  self-invisible, for a one-env-var gain. Full danger analysis:
  `Plan/Ideas/PostRelease/2026-06-07-tier2-lsp-auto-move.md`. Revisit if the
  engine exposes a port-readback API or a per-project LSP port
  (godot-proposals #11056).

Source-verified analysis (engine 4.2–4.6, the issue tracker, ecosystem prior
art): `Insights/lsp-multi-instance-port-analysis.md`. Iteration:
`Plan/ExecutionPlan/41l-tertricies-lsp-port-discovery.md`.
