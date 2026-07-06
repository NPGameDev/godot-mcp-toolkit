# macOS GUI-launch Node/PATH — OS-aware `.mcp.json` emission

> **Superseded by [ADR 0018](0018-macos-launch-minimize.md) — 2026-07-05.** The
> mac-gate real-Mac validation refuted the launchd-PATH premise for current GUI
> clients.

On macOS, an app launched from Finder / Dock / Spotlight runs under `launchd`
with a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) and **never sources the
user's shell rc files**. Node installed via nvm / fnm / volta / Apple-Silicon
Homebrew (`/opt/homebrew/bin`) is therefore invisible to a **GUI-launched MCP
client** (Claude Desktop, Cursor.app, VS Code.app): the client can't spawn our
server (`spawn npx ENOENT`) and silently fails to connect. CLI clients (Claude
Code from a terminal) inherit the shell `PATH` and are unaffected.

The toolkit's dock / wizard / Tools-menu all write `.mcp.json` through
`ui/mcp_json_sync.gd`, which **byte-copied** `.mcp.json.template`. A static copy
cannot carry the one thing that fixes this — a machine-resolved absolute path — so
every Node-based Godot MCP project surveyed has this exact limitation and none
document or fix it.

## Decision

**Make the `.mcp.json` write OS-aware, and on macOS emit a toolkit-resolved
absolute `node`/`npx` path (plus a resolved `env.PATH` backstop) so the client
bypasses the `launchd` PATH lookup entirely.**

- **macOS — option (d), toolkit-resolved absolute path.** `nodejs_check.gd` gains
  a login-shell probe (`resolve_launch_paths`) that reuses the same
  `OS.execute($SHELL, ["-l","-c", …])` technique the version check already uses to
  discover the user's real absolute `node` and resolved `$PATH`. The builder emits
  the absolute `npx` (derived beside `node`) for the release form with the resolved
  `PATH` as a backstop for the npx-shebang re-resolution gap; the dev/local form
  (`GODOT_MCP_DEV_SERVER_PATH` set) runs the absolute `node` against the dist entry
  — the strongest shape, dodging shebang re-resolution. Regenerated on the dock's
  "Write" **and on editor start** (guarded: only refreshes an existing, writable,
  well-formed file), which erases the sole weakness of an absolute path
  (staleness after a Node-version switch).
- **Windows** — `cmd /c npx -y @npgamedev/godot-mcp-server` (no `launchd` bug; `npx`
  is a `.cmd` shim that needs `cmd /c`).
- **Linux / unknown OS** — bare `npx -y @npgamedev/godot-mcp-server`.
- **Command base** — release (`@npgamedev/godot-mcp-server`) by default; a
  `GODOT_MCP_DEV_SERVER_PATH` env override emits the local-dist `node <path>` form,
  serving both Windows dogfooding and pointing a Mac at a local build. No
  machine-specific path is ever hardcoded (the template was reconciled from a
  machine-specific dogfood form to a portable env/shape skeleton).

The OS-shape logic is a **pure** `build_server_entry(os_name, resolved_node,
resolved_path, dev_server_path)` (headless-unit-tested field-by-field), fed by the
**impure** macOS resolver; the write merges the template's base `env`
(`GODOT_MCP_CONFIG_VERSION`) beneath the builder-owned PATH key.

### Why option (d) over the wrapper / `env`-PATH forms

Two quarantined web-research agents (no repo access) settled the form:

- **`zsh -lc 'exec …'` wrapper — rejected as default, documented fallback only.**
  Login shells source rc files (`~/.zprofile`, p10k, nvm banners) **before** the
  command runs, and the stdio MCP transport treats a single stray stdout byte as
  fatal to the JSON-RPC handshake; `exec` cannot remove bytes already emitted. Risk
  is MEDIUM–HIGH. It also misses nvm-in-`~/.zshrc` (login-non-interactive skips it).
  Evidence: `Plan/Reference/Resources/macos-node-launch/03-wrapper-stdio-safety.md`.
- **`env`-PATH override — documented fallback only.** The `env` block *replaces*
  rather than merges the environment, so it carries the same staleness surface as an
  absolute path with more ways to get it wrong.
- **Absolute path — chosen.** Every major stdio client accepts a full path as
  `command` and spawns it directly (VS Code spec: *"or contain its full path"*); it
  is the ecosystem's most-recommended fix, is stdio-safe (no wrapper shell → nothing
  can echo into the handshake), and its only weakness (staleness) is erased by the
  on-demand + on-start regeneration this plugin already owns. Evidence:
  `Plan/Reference/Resources/macos-node-launch/04-absolute-path-config-viability.md`.

### Why layer D (server-side PATH self-heal) was cut

The originally-scoped fourth layer — a server-side `PATH` self-heal — was cut. The
server is a thin stdio bridge that **spawns nothing** and never reads `PATH`
(grep-verified: no `child_process` / `exec` / `process.env.PATH` in `src/`), and the
`spawn npx ENOENT` failure happens in the *client*, **before** the server starts —
so a server-side heal can neither fix the pre-start failure nor protect any
post-start work. Deferred to
`Plan/Ideas/PostRelease/2026-07-04-server-path-self-heal-revisit.md` (revisit only
if the server ever gains PATH-dependent work).

## Considered alternatives

- **Keep byte-copying a single template.** Rejected — a static file can't carry a
  machine-resolved path, which is the whole fix; and the template was already a
  machine-specific dogfood copy (non-portable).
- **Resolve on the client side / tell users to launch from a terminal.** Rejected as
  the default — that is the status quo that fails silently; a terminal launch remains
  a documented diagnostic, not the fix.
- **Emit only a resolved `env.PATH`, keep bare `npx`.** Weaker than an absolute
  command (still a PATH lookup that can miss), so `PATH` is used only as the macOS
  backstop for the npx-shebang gap, paired with the absolute command.

Graceful degradation: when resolution fails (node absent, nvm-only-in-`~/.zshrc`,
Fish/Nushell) the builder emits the bare `npx`/`node` form and recovery leans on the
dock's macOS "listening, no peer" nudge (layer C) and the server README guidance
(layer B) — the write is never blocked.

Iteration: `Plan/ExecutionPlan/41n-undecies-bis-macos-node-launch-ux.md`; grill log
`Plan/Reference/GrillingSessions/2026-07-04-macos-node-launch-ux.md`.
