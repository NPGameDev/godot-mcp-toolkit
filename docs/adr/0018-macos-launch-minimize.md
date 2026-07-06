# Minimize the macOS `.mcp.json` emission — revert to bare `npx`

ADR [0017](0017-macos-gui-launch-path.md) made the `.mcp.json` write emit a
toolkit-resolved **absolute `node`/`npx`** command plus an `env.PATH` backstop on
macOS, and re-derived it on editor start, on the premise that a GUI-launched MCP
client (Claude Desktop, Cursor.app, VS Code.app) runs under `launchd` with a
minimal `PATH` and cannot find a version-manager Node.

The `41n-undecies-bis-mac-gate` real-Mac validation (2026-07-05, **Claude Desktop
1.11187.4** with Node under **fnm**) **refuted that premise for current GUI
clients**. The client resolved a **bare `npx`** to fnm's Node on its own — modern
desktop clients capture the login shell's environment before spawning the server —
so the absolute pin was redundant. Worse, the toolkit's resolved path was an
**ephemeral** `fnm_multishells/…` path: a capable client spawns that literal path,
which can point at a shell session that no longer exists, **overriding the client's
own working resolution** (net-negative). Core macOS function was otherwise validated
end-to-end (35 tools driven from `claude`).

## Decision

**Emit a plain per-OS `npx` command on macOS — the same shape as Linux — and drop
the resolver, the absolute-path branch, the `env.PATH` backstop, and the
editor-start refresh.**

- **macOS** — bare `npx -y @npgamedev/godot-mcp-server` (identical to Linux). No
  resolved absolute path, no `env.PATH`, no login-shell probe on the write path.
- **Windows** — unchanged: `cmd /c npx -y @npgamedev/godot-mcp-server` (`npx` is a
  `.cmd` shim that needs `cmd /c`).
- **Command base** — unchanged: release (`@npgamedev/godot-mcp-server`) by default;
  a `GODOT_MCP_DEV_SERVER_PATH` env override emits the local-dist `node <path>` form.
- **No auto-refresh** — the write happens only on explicit user action (dock /
  Tools-menu / wizard "Write .mcp.json"); opening the editor no longer rewrites the
  file. Existing `GODOT_MCP_*` user keys are still preserved on a rewrite.
- **Layer C nudge kept, reworded** — the dock's macOS "listening, no peer" panel
  stays, but as a **generic** "no MCP client has connected — how to diagnose" nudge
  with no `launchd`/PATH causal claim. **(Superseded 2026-07-06 — see the Update
  below: Layer C was removed entirely.)**
- **Docs rewritten honestly** — advanced-configuration, the server README, and the
  compatibility notes describe the standard `npx` config working from Finder/Dock or
  a terminal, with a terminal-launch diagnostic if a client won't connect.

## Consequences

- The emitted config is simpler, always tracks the user's current Node, and can
  never override a capable client with a stale absolute path.
- **Supersedes ADR 0017.** The absolute-path emission, the PATH backstop, and the
  startup refresh are removed, not shimmed (pre-1.0 clean break).
- The `.mcp.json` wire shape reverts to bare `npx` on macOS; the server side is
  unaffected — it reconciles only `GODOT_MCP_*` keys, not the command/args.
- **Auto-resolving an absolute Node path is deferred, evidence-gated.** Re-add it
  only if a real user report surfaces a raw-`launchd` client that genuinely cannot
  resolve a bare `npx` (none observed on current desktop clients).

Iteration: `Plan/ExecutionPlan/41n-undecies-quinquies-macos-launch-minimize.md`;
premise-flip finding `Plan/ExecutionPlan/41n-undecies-bis-mac-gate-real-mac-validation.md`.

## Update — 2026-07-06: Layer C removed

The "Layer C nudge kept, reworded" decision above is **superseded**: the dock's
macOS "listening, but no client connected after a grace period" panel was
**removed entirely**, along with its predicate, ~20 s no-peer grace timer, and
session-dismiss latch.

Rationale: the panel **false-alarmed a normal workflow** — opening the editor
before wiring up an MCP client is routine, so the panel would nag after its grace
even when nothing was wrong. The dock's **peer-count status row** already signals
whether a client is connected, and a genuine connection failure surfaces its own
error, so the nudge added noise without adding signal.

The honest terminal-launch diagnostic guidance (check the client is running,
confirm `.mcp.json` is present, launch from a terminal to see the startup error)
stays in `COMPATIBILITY.md` and the shipped `advanced_configuration.md`; only the
dock panel is gone.
