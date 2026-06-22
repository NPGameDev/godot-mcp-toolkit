# Multi-Instance / Multiplayer Setup

Developers testing P2P or multiplayer networking often run two Godot editors
simultaneously (one as server, one as client). The MCP architecture handles
this, but only under the correct setup. Three patterns exist:

---

## Pattern A -- Two copies in different directories: SUPPORTED (recommended)

Use `git worktree add` or copy the project folder so each editor instance
opens a distinct absolute path. The plugin's path-keyed registry, per-worktree
token hashing, and dynamic port allocation give each instance its own port,
token, registry entry, and MCP client session.

```
git worktree add ../MyGame-client client-branch
# Open each folder in a separate Godot editor
# Each gets its own MCP port + token automatically
```

**How it works:**
- Each editor scans ports 6550-6560 and binds the first free one.
- The system-wide `projects.json` registry maps each absolute path to its port.
- The TypeScript bridge resolves the correct port by matching `process.cwd()`
  (or `GODOT_MCP_PROJECT_PATH`) against the registry.
- Per-worktree token hashing ensures auth tokens don't collide.

**Log contention caveat:** Both copies share `user://logs/godot.log` if they
have the same `config/name` in Project Settings. This affects MCP log commands:

- `editor_get_console(source:"file")` and `debugger_get_log(source:"file")`
  read this shared log, so output from both instances is interleaved.
- On **Godot 4.5+**, `source:"buffer"` uses the in-memory LogBuffer (Logger
  API), which is isolated per editor process — no cross-instance contamination.
  Prefer `source:"buffer"` for multi-instance setups.
- On **Godot 4.2–4.4**, buffer mode falls back to file-tail, so it reads the
  same shared log file and is equally affected by interleaving.

**Workaround:** Give each copy a distinct `application/config/name` in Project
Settings. Godot uses this to derive the `user://` directory path, which
separates the log files. With git worktrees this is easy — change the name in
the worktree copy only.

---

## Pattern B -- Godot's built-in "Run Multiple Instances": MOSTLY SUPPORTED

Single editor, multiple game processes (Project Settings > Run > Run Multiple
Instances).

- **Editor MCP (Mode A):** unaffected -- single editor, single Mode A port.
- **Runtime MCP (Mode B):** dynamic port allocation works -- each game process
  binds a distinct port from the 6570-6585 range. However, the registry's
  single `runtime_port` field per entry means only the last-started game
  process is bridge-discoverable.

This is a minor limitation. MCP usage during multiplayer testing is
predominantly Mode A (editor introspection), not Mode B (runtime
introspection).

The editor's debug bridge has the same single-session limit: it tracks only
the most-recently-launched game process, so `debug_state`, `debug_continue`,
and the `debugger_get_log` error buffer reflect that last instance only. For
per-instance debugging of several running games at once, use Pattern A
(separate editors), where each instance has its own editor and debug bridge.

---

## Pattern C -- Same project, same directory, two editors: NOT SUPPORTED

Two Godot editors opening the same project directory simultaneously causes:

- **Registry key collision:** the registry is keyed by project-root hash, so
  both editors map to the *same* slot. The registry tracks only the
  **last-registering** instance — it's last-writer-wins, *not* a guaranteed
  newest-wins, so the second editor clobbers the first's entry (port, token
  path) and which instance the bridge resolves to is undefined.
- **Token collision:** same absolute path produces the same hashed token
  filename, so auth fails on reconnect.
- **Godot-level issues:** metadata lock warnings, `user://` cache corruption
  risk. This is also a Godot anti-pattern — the engine itself does not
  officially support opening one project path in two editors (the GDScript
  debugger port is a single global setting, and concurrent editors race on
  shared `user://` temp files): see upstream
  [godotengine/godot#58723](https://github.com/godotengine/godot/issues/58723)
  and [#16679](https://github.com/godotengine/godot/issues/16679).

**Use Pattern A instead.** `git worktree add` takes seconds and gives you
full isolation.

---

## GDScript LSP in two editors at once

The `lsp_*` tools (diagnostics, symbols, hover, completion, definition,
references) reach Godot's built-in **GDScript Language Server**, which binds a
single **machine-wide** TCP port (default **6005**) — *not* per project. This is
independent of the per-project WebSocket above: **any two editors collide on it —
same-project worktrees (Pattern A) *or* two unrelated projects alike** — because
they share the one 6005. When the second editor can't bind 6005 its LSP fails
silently, so without the setup below the second project's `lsp_*` tools would
reach the *first* editor.

The toolkit publishes each editor's LSP endpoint to the registry and the server
discovers it per project, but the engine consumes `--lsp-port` before the plugin
can observe it — so a second editor needs **both** a distinct launch port and a
matching env var:

> **Recipe.** Give each extra editor its own LSP port (`--lsp-port`; note the
> **space**, not `=`; Godot ≥ 4.2) **and** tell that editor's MCP server the
> matching port via `GODOT_MCP_LSP_PORT`:
>
> ```bash
> godot --editor --path /path/to/projectB --lsp-port 6006
> ```
> ```json
> // projectB/.mcp.json — env block
> "env": { "GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_LSP_PORT": "6006" }
> ```
>
> The default editor (A) needs nothing — it keeps 6005 and the server discovers
> it. `GODOT_MCP_LSP_HOST` overrides the host the same way (rarely needed — the
> LSP is localhost). These mirror the familiar `lsp.serverPort` / `lsp.serverHost`
> client settings.

**Without** a distinct `--lsp-port`, the second editor's server reports a visible
`LSP_PORT_CONFLICT` and refuses to answer — it will **not** silently return the
other project's results.

> **Godot 4.2–4.4.** The cross-project safety net (workspace-root verification)
> needs Godot **4.5+**. On 4.2–4.4 the server cannot detect a foreign or
> near-simultaneous holder of port 6005, so **always** give each editor a distinct
> `--lsp-port` + `GODOT_MCP_LSP_PORT` before using `lsp_*` tools with more than one
> editor open.

---

## Quick reference

| Pattern | Setup | Status |
|---------|-------|--------|
| A: Two copies (git worktree) | Separate directories | SUPPORTED |
| B: Built-in multi-instance run | Single editor, multiple game processes | MOSTLY SUPPORTED |
| C: Same dir, two editors | Same project path | NOT SUPPORTED |

## See also

- [Multi-project support](../CLAUDE.md#multi-project-support-iter-23) in the
  toolkit CLAUDE.md
- `GODOT_MCP_PROJECT_PATH` env var for decoupled CWD setups
