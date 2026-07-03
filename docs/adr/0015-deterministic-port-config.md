# Deterministic port configuration (listen-side env, CLI flags, desync safety)

The MCP **server** (connect side) could already pin all three channels — editor
WS, runtime WS, LSP — via env vars, but the **toolkit** (listen side) was
hardcoded and read **zero** port env. So a user could tell the server *where to
dial* yet could not tell the toolkit *where to bind* — parallel / multi-instance
setups were left dependent on registry discovery (the file-lock + liveness-probe
contention that motivates deterministic ports). Worse, a pin set on the server
only (the normal `.mcp.json` case) made the server dial a port nobody listened on
→ a **silent dead-socket hang**, because *an environment variable is not a sync
channel — it is two independent per-process reads*.

Two of the three channels are **dynamic** (editor WS, runtime WS — they scan a
band). The LSP port is Godot's to bind, not the toolkit's.

**Decision: give each dynamic channel a listen-side env config with two exclusive
modes (Pinned / Scanned), make a pinned port bind-exact-or-fail with a loud
surface, keep the connect side in lockstep through one clean-renamed var, and make
a listen/dial desync fail fast instead of hanging.**

- **Two modes per channel, mutually exclusive.** *Pinned* (`GODOT_MCP_EDITOR_PORT`
  / `GODOT_MCP_RUNTIME_PORT`) binds that exact port or **fails** — never scans
  elsewhere. *Scanned* (no pin) scans a band and publishes the bound port for
  discovery. A pin present ⇒ the `_MIN`/`_MAX` band is **ignored** (a one-line log
  note), never blended. Band defaults are today's literal ranges (editor
  6550–6560, runtime 6570–6585, inclusive); `_MIN`/`_MAX` relocate them. A
  malformed pin, an out-of-range port (1–65535), or `MIN > MAX` is a **clear
  error** (dock + log), never a silent default.
- **Bind-exact-or-fail with a bounded grace.** A pinned-but-occupied port reuses
  the existing throttled `ERR_ALREADY_IN_USE` retry as a **bounded same-port
  grace** — it rides out a prior instance still releasing the port on restart —
  then logs a precise error naming the pinned port, and keeps watching so a later
  free still recovers. A late bind **re-publishes** the registry entry (the
  fresh-bind seam drives registration), so the published port stays ground truth
  in every mode. The editor surfaces any not-listening state — pinned port
  occupied, scan band exhausted, or invalid config — as a **persistent dock
  warning + a warning-styled status row** (immediate); the runtime, a child game
  process that cannot reach the dock, surfaces a loud `push_error` in the game
  console (captured by the console tools). It never falls back to a different
  port and never hangs silently.
- **Export-safe shared resolver.** One resolver (`transport/port_config.gd`) reads
  the env and returns the resolved mode/port/band/source, consumed by both
  `transport/mcp_server.gd` and the Mode-B `runtime/mcp_runtime_server.gd`. It
  names **zero** `Editor*` symbols and preloads nothing editor-tainted — the
  runtime autoload preloads it, and GDScript resolves identifiers at parse time,
  so any editor reference would parse-fail the autoload in an export template
  (godot#91713). No `class_name`; the env lookup is an injectable Callable so the
  pure resolution logic is unit-testable headlessly.
- **Listen vs. connect is a real split.** The env pins are read by **both** sides —
  the editor/game to *listen*, the server to *dial* — so one value inherited by
  both processes makes them agree with zero discovery. The `_MIN`/`_MAX` band vars
  are **listen-side only**; the server never reads them (discovery covers the
  scanned case). The server also gains explicit CLI flags (`--editor-port` /
  `--runtime-port` / `--lsp-port` / `--lsp-host`) with precedence **CLI > env >
  registry discovery > default**; CLI can only move the *dial* target — it cannot
  reach the toolkit's listen port, which is the asymmetry that makes the
  cross-check below mandatory.
- **Clean rename `GODOT_MCP_PORT` → `GODOT_MCP_EDITOR_PORT`.** Pre-1.0, no alias,
  symmetric with `GODOT_MCP_RUNTIME_PORT` / `GODOT_MCP_LSP_PORT`. The dead `--lite`
  / `GODOT_MCP_PROFILE` deprecation stubs are removed in the same pass.
- **Fail-fast desync cross-check.** When a pin is in effect and discovery is
  skipped, the server does **one** registry read at connect to verify the live
  editor for this project is actually on the pinned port. A mismatch is a
  **precise, actionable error** ("pinned to 6557, but the live editor is on 6550 —
  launch the editor with the same `GODOT_MCP_EDITOR_PORT`"), never a silent
  timeout. The toolkit keeps publishing its **real** bound port in every mode (pin
  included) precisely so this check has ground truth.

## LSP stays connect-pin-only

The GDScript LSP is **not** given a listen-side env. Godot consumes `--lsp-port`
before it reaches `OS.get_cmdline_args()` and exposes no API to read the effective
port, so GDScript cannot know or assert the real LSP port (`lsp_publisher.gd`;
ADR 0008). A listen-side LSP env could therefore only blindly assert a value it
cannot verify. LSP stays connect-pin-only via the server-side `GODOT_MCP_LSP_PORT`
/ `GODOT_MCP_LSP_HOST`, with the server-reported dock verdict already covering
health and conflicts.

## Considered alternatives

- **Warn-then-scan on a pinned-port conflict** (fall back to another port).
  Rejected — it defeats the whole point of a pin (determinism). A pin that
  silently moves is worse than no pin; the failure must be loud and the port
  identity must hold.
- **Reconcile a desync (adopt the live editor's port instead of the pin).**
  Rejected — exclusivity means there is no band to tolerate, and adopting a
  different port silently is exactly the ambiguity a pin exists to remove. Fail
  fast, don't reconcile.
- **A one-shot `--port-set editor:runtime:lsp` CLI convenience form.** Rejected as
  YAGNI — the explicit per-channel flags are clearer and the surface is tiny.

Iteration: `Plan/ExecutionPlan/41n-decies-deterministic-port-config.md`; grill log
`Plan/Reference/GrillingSessions/2026-07-03-deterministic-port-config.md`.
