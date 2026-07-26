---
title: Troubleshooting
permalink: /troubleshooting/
nav_order: 3
---

# Troubleshooting

The canonical symptom-to-fix reference for the Godot MCP Toolkit and its
companion server. If something does not connect, start with the 60-second
checklist; if a specific tool misbehaves, jump to its symptom below.

## The 60-second checklist

Most connection problems are one of these five:

1. **Is the editor open with the plugin active?** Project Settings → Plugins →
   "Godot MCP Toolkit" → Active. The MCP dock appears in the bottom panel.
2. **Did the WebSocket server come up?** The editor's Output log shows
   `[MCPServer] listening on 127.0.0.1:6550` (the port may be anywhere in
   6550–6560; the dock's status section shows the live state).
3. **Is `.mcp.json` present at the project root?** The dock's `.mcp.json`
   section tells you — and offers to create or fix it.
4. **Is Node.js 22 or newer installed?** `node --version` should print `v22` or
   higher.
5. **Was the MCP client launched from the project root, and reconnected after
   any config change?** Clients read `.mcp.json` at startup — a config edit
   (including toggling read-only mode) takes effect on the next connect, not
   mid-session.

## Connectivity probe

Three commands that isolate where a connection fails, without guessing:

**Is anything listening on the editor port?**

```bash
# Windows
netstat -ano | findstr :6550

# macOS / Linux
lsof -iTCP:6550 -sTCP:LISTEN
```

If nothing listens on 6550, check the next ports in the band (6551–6560) — the
editor scans forward when the default is taken. The dock's status section names
the bound port exactly.

**Is the server package installed and runnable?** This needs no editor at all:

```bash
npx -y @npgamedev/godot-mcp-server --tools-count
```

It prints a tool-count summary and exits. If this fails, the problem is Node or
the package install, not Godot.

**What should success look like?** On a healthy editor launch the Output log
shows the `[MCPServer] listening on 127.0.0.1:<port>` line; during a playtest
the dock's status section additionally shows
`Runtime: listening on 127.0.0.1:<port>`.

## Symptoms and fixes

### The client cannot connect, or connects to the wrong port

**Cause:** by default the editor scans a small port band (6550–6560), publishes
the bound port to a machine-wide registry, and the server discovers it from
there — zero configuration. Connection failures here usually mean a pinned port
that only one side can see, or a stale process holding a port.

**Fix:** if you have no reason to pin, remove any `GODOT_MCP_EDITOR_PORT`
setting and let discovery do its job. If you do pin (firewalls, containers,
scripts):

> [!IMPORTANT]
> A pinned port must be visible to **both** processes. `GODOT_MCP_EDITOR_PORT`
> in the `.mcp.json` `env` block reaches only the server (the dialing side);
> the editor (the listening side) reads the same variable from *its own*
> environment, so launch Godot from a shell that exports it. A pin only one
> side sees means the editor binds one port while the server dials another —
> nothing connects.

A pinned port that is already occupied fails loudly with a dock warning naming
the port — free the port or change the pin. The full mechanism (pin vs scan
band, per-channel variables) is in the shipped
[`advanced_configuration.md`](../addons/godot_mcp_toolkit/docs/advanced_configuration.md).

### macOS: a GUI-launched client will not connect

**Cause:** modern GUI-launched MCP clients (Claude Desktop, Cursor, VS Code)
capture your login shell's environment and resolve a bare `npx` themselves, so
the standard config normally works whether you launch from Finder/Dock or a
terminal. When it does not, the client's environment is missing Node.

**Fix:** launch the client from a terminal to see its startup error, confirm
`.mcp.json` is present at the project root, and confirm `node --version` prints
22+. If your Node lives behind a version manager whose init is only in
`~/.zshrc`, move it into `~/.zprofile` so login-shell launches see it too — or
install Node from the [nodejs.org](https://nodejs.org) installer, which lands
on the default `PATH` with zero setup. Full diagnosis and fallbacks are in the
shipped
[`advanced_configuration.md`](../addons/godot_mcp_toolkit/docs/advanced_configuration.md)
(macOS section).

### Windows: the server entry never starts

**Cause:** on Windows `npx` is a `.cmd` shim, not an executable — an
`.mcp.json` that invokes `npx` directly fails to spawn.

**Fix:** the plugin writes the correct form automatically
(`"command": "cmd"` with `/c npx …` in the args). If you hand-wrote your
`.mcp.json`, mirror that shape, or let the dock regenerate the file.

### npm says "could not determine executable to run", or an old version starts

**Symptom:** the server entry fails to launch with npm's
`could not determine executable to run`, or it launches but behaves like a
version you already upgraded away from.

**Cause:** `npx` keeps its own cache of downloaded packages. A stale cached
copy can shadow the version you just installed or upgraded — including a copy
cached before the package was fully published, which has no executable at all.

**Fix:** reinstall the current version globally —
`npm install -g @npgamedev/godot-mcp-server@latest` — and retry. If `npx`
still resolves the stale copy, delete the `_npx` folder inside your npm cache
directory (`npm config get cache` prints its location) and try again.

### Log tools return `LOG_BUSY`

**Symptom:** `editor_get_console` or `debugger_get_log` with `source="file"`
reports the log is busy.

**Cause:** the log file exists but a read could not open it. On Windows the
dominant cause is a **running game**: the editor's read requests deny-write
sharing, which the OS refuses while the game process holds the log open for
writing. With no game running, an antivirus, backup, or file-sync tool may be
holding it briefly.

**Fix:** on Godot 4.5+ use `source="buffer"` (in-memory, no file involved —
reads even while the game runs). Otherwise stop the game and retry; if no game
is running, retry shortly.

### Log tools return `LOG_UNAVAILABLE`

**Symptom:** the same tools report the log cannot be found or read.

**Cause:** file logging is disabled (or the log file is missing).

**Fix:** enable **Project Settings → Debug → File Logging → Enable File
Logging** (`debug/file_logging/enable_file_logging`), then restart the editor.
On Godot 4.5+, `source="buffer"` works without file logging.

### Tools are missing — every mutating tool is gone

**Symptom:** the agent sees only read-style tools; creation and editing tools
are absent.

**Cause:** read-only mode is on. `GODOT_MCP_READ_ONLY=1` (set via the dock's
read-only toggle, which syncs it into `.mcp.json`) hides every mutating tool
from the client — that is the feature working as designed.

**Fix:** turn the dock's read-only toggle off, then **reconnect the MCP
client** — the tool list is decided at connect time, so a reconnect (not an
editor restart) picks up the change.

### The dock flags `.mcp.json`, or the project was moved

**Symptom:** the dock's `.mcp.json` section shows a warning (invalid JSON,
stale contents, wrong paths after moving or copying the project).

**Fix:** click **Fix .mcp.json** in the dock — it rewrites the file from a
clean template. If you keep hand edits in the file, back them up first; the fix
overwrites.

### Deleted the `.godot/` folder

**Symptom:** after clearing the project cache (a common fix for import
weirdness), plugin state looks off.

**Fix:** usually nothing — the plugin detects the loss and re-creates its state
on a retry timer. If the dock has not recovered after a few seconds, restart
the editor.

### Multiple editors or git worktrees

Running several editors side by side is supported — each project instance gets
its own isolated state and its own port. The rules and patterns are in the
shipped
[`multi-instance.md`](../addons/godot_mcp_toolkit/docs/multi-instance.md).

### C# project: scripts will not load, or C# tools error

> [!IMPORTANT]
> C# projects require the **.NET (mono) Godot editor build** — the standard
> build cannot load `.cs` scripts at all.

See the C# section of the shipped
[`compatibility.md`](../addons/godot_mcp_toolkit/docs/compatibility.md) for
version requirements and details.

### Windows: a headless CLI export never returns

**Symptom:** `godot --headless … --export-release` (or `--export-debug`) writes
the build successfully, but the command never exits — the console window sits
there until you kill it. Godot 4.4.x and older only.

**Cause:** `Godot_v*_console.exe` is a wrapper that waits for **every**
descendant process to exit. On 4.4.x and older, a CLI export restores the
previous editor session *after* the export finishes, re-opening the scenes and
scripts you last had open. If **Editor Settings → Text Editor → External → Use
External Editor** is enabled, that restore launches your external editor, and
the wrapper keeps waiting on it — while the export itself already succeeded.

> [!IMPORTANT]
> Editor settings are stored **per minor version**
> (`%APPDATA%\Godot\editor_settings-4.<minor>.tres`), so an older Godot you
> export with can still have the external-editor setting enabled even when your
> current version does not.

**Fix:** on 4.4.x and older, any one of these clears it — disable the
external-editor setting for the Godot version you export with, invoke the
non-console executable instead of the `_console` one, or export from a clean
checkout that carries no `.godot/editor/` session state. Godot **4.5 fixed the
restore** (engine commit `5d868a66c0`), so the hang cannot happen on 4.5+ even
with the setting enabled.

This is not specific to this addon — it reproduces with the addon disabled.
Related upstream reports:
[godotengine/godot#110101](https://github.com/godotengine/godot/issues/110101)
(same wrapper mechanism, a different child process) and
[godotengine/godot#103305](https://github.com/godotengine/godot/issues/103305)
(a headless run still loads the editor layout).

## Still stuck?

Open an issue on
[GitHub](https://github.com/NPGameDev/godot-mcp-toolkit/issues) with your
Godot version, OS, the checklist results, and the relevant Output-log lines —
those five facts locate almost every problem.
