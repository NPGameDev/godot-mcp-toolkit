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
- Each editor scans ports 6505-6515 and binds the first free one.
- The system-wide `projects.json` registry maps each absolute path to its port.
- The TypeScript bridge resolves the correct port by matching `process.cwd()`
  (or `GODOT_MCP_PROJECT_PATH`) against the registry.
- Per-worktree token hashing ensures auth tokens don't collide.

**Only limitation:** shared `user://logs/godot.log` if both copies have the
same `config/name` in Project Settings.

---

## Pattern B -- Godot's built-in "Run Multiple Instances": MOSTLY SUPPORTED

Single editor, multiple game processes (Project Settings > Run > Run Multiple
Instances).

- **Editor MCP (Mode A):** unaffected -- single editor, single Mode A port.
- **Runtime MCP (Mode B):** dynamic port allocation works -- each game process
  binds a distinct port from the 6525-6540 range. However, the registry's
  single `runtime_port` field per entry means only the last-started game
  process is bridge-discoverable.

This is a minor limitation. MCP usage during multiplayer testing is
predominantly Mode A (editor introspection), not Mode B (runtime
introspection).

---

## Pattern C -- Same project, same directory, two editors: NOT SUPPORTED

Two Godot editors opening the same project directory simultaneously causes:

- **Registry key collision:** same `project_path` means the second editor
  overwrites the first's entry (port, token path).
- **Token collision:** same absolute path produces the same hashed token
  filename, so auth fails on reconnect.
- **Godot-level issues:** metadata lock warnings, `user://` cache corruption
  risk. This is also a Godot anti-pattern.

**Use Pattern A instead.** `git worktree add` takes seconds and gives you
full isolation.

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
