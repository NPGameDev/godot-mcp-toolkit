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

**Cause:** on Windows `npx` is a `.cmd` shim, not an executable, and some MCP
clients, older Claude Code among them, cannot start it directly.

**Fix:** On Windows the dock writes the wrapped form for you (`"command": "cmd"`
with `/c npx …` in the args); to switch a hand-written `.mcp.json` to it, let the
dock regenerate the file.
If Claude Code on Windows shows the server failed with `spawn npx ENOENT` or `EINVAL`, update Claude Code or wrap the command in `cmd /c`.

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

**Cause:** the log file exists but a read could not open it. For
`editor_get_console` on Windows the dominant cause is a **running game**: the
editor's read requests deny-write sharing, which the OS refuses while the game
process holds the log open for writing. `debugger_get_log` is read by the game
itself while it runs, and that read shares the file, so there the cause is an
antivirus, backup, or file-sync tool holding it briefly, as it is for either
tool with no game running. When the game cannot answer, as at an error break,
`debugger_get_log` reads from the editor and does not return `LOG_BUSY`: it
returns `debug_state` and any caught errors, which at an error break name the
file and line the editor's debugger reports, with a note on how to get the log
lines.

**Fix:** on Godot 4.5+ use `source="buffer"` (in-memory, no file involved —
reads even while the game runs). Otherwise stop the game and retry; if no game
is running, retry shortly.

### Log tools return `LOG_UNAVAILABLE`

**Symptom:** the same tools report the log cannot be found or read.

**Cause:** file logging is disabled (or the log file is missing).

**Fix:** enable **Project Settings → Debug → File Logging → Enable File
Logging** (`debug/file_logging/enable_file_logging`), then restart the editor.
On Godot 4.5+, `source="buffer"` works without file logging.

### The game is paused at a script error

**Symptom:** `game_start` returns early with a hint that the game is paused at
a script error and cannot continue, or `debugger_get_log` returns a `break`
entry that says so.

**Cause:** the editor's debugger stopped the game at an error break: a parse
error, a script that failed to load, or a runtime error such as a method called
on a null value. The game can't continue from it. The entry and the hint quote
the error the debugger reports and the file and line it stopped at. When a
script's `preload()` fails, the game stops on the preloading line, and the text
names the preloaded script that holds the error. When the debugger reports no
location, the `break` entry says to find the file and line with `script_check` or
`lsp_project_diagnostics`. That advice fits a parse error; a runtime error
compiles, so those checks don't find it. Stop the game and read
`debugger_get_log` again, or look in the editor's Debugger panel.

**Fix:** correct the script, then call `game_stop` and `game_start`.

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

**Symptom:** the dock's `.mcp.json` section shows a warning (invalid JSON, or an
`mcpServers` that isn't an object; stale contents; wrong paths after moving or
copying the project).

**Fix:** for invalid JSON or an `mcpServers` that isn't an object, click
**Open .mcp.json** in the dock, fix the file and save; or delete it and click
**Write .mcp.json**. The toolkit never overwrites a file in either state. For
stale contents or wrong paths,
use **Project → Tools → MCP Toolkit → Write .mcp.json**; it asks before it
updates the `godot-mcp-toolkit` entry, and keeps your other servers and env keys.

### `.mcp.json` shows modified after a write from another OS

**Symptom:** `git status` shows `.mcp.json` modified after the dock wrote it on
a different OS from the one that wrote the committed copy.

**Cause:** the dock writes the server entry in the form for its own OS:
`cmd /c npx` on Windows, bare `npx` on macOS and Linux.

**Fix:** Working across Windows and macOS/Linux? Keep `.mcp.json` out of version control and let each machine write its own; the toolkit offers to on first open.

Alternatively: Commit the macOS/Linux form; current Claude Code on Windows starts it. Discard the change a Windows write makes.

A future release will write the same entry on every OS.

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

### The Output log names another editor's registry entry

**Symptom:** at editor start the Output log shows one of these lines:

- a warning, `[MCPRegistry] found an entry from PID <n> (another editor on this project, or one that did not exit cleanly); overwriting with PID <m>`
- an info line, `[MCPRegistry] replaced an entry from PID <n>, an editor that did not exit cleanly`

**Cause:** the registry keeps one entry per project, and this editor found one
that another editor process left. If that entry names the port this editor
has just bound, the old editor is gone, since two processes cannot listen on
one port. The entry was left by an editor that crashed or was killed, so the
registry replaces it and prints the info line. If the entry names another
port, the registry cannot tell which case it is and warns: a second editor
has this project open, which is not supported, or an editor that did not exit
cleanly had bound a different port.

**Fix:** the info line needs nothing. For the warning, close any other editor
that has this project folder open; to run two editors, give each its own copy
of the project (Pattern A in
[`multi-instance.md`](../addons/godot_mcp_toolkit/docs/multi-instance.md)). If
no other editor is open, the entry was a leftover and needs nothing either.

### C# project: scripts will not load, or C# tools error

> [!IMPORTANT]
> C# projects require the **.NET (mono) Godot editor build** — the standard
> build cannot load `.cs` scripts at all.

See the C# section of the shipped
[`compatibility.md`](../addons/godot_mcp_toolkit/docs/compatibility.md) for
version requirements and details.

### An update did not install, or the toolkit stopped loading after one

The update badge in the dock says what went wrong. Every step and every failure
also goes to `addons/.godot_mcp_toolkit_update/install.log`. The editor hides
that folder, so open it in your file manager. The shipped
[`self-update.md`](../addons/godot_mcp_toolkit/docs/self-update.md) says what an
update downloads and writes, and when.

**When a check fails.** The toolkit checks a release before it offers it, and
again each time you click **Update**. If a check fails, the badge shows one of
these messages:

- **"Couldn't reach GitHub to check this update."** There was no answer: no
  connection, a timeout, or a failed TLS handshake. Check your connection, then
  click **Update**.
- **"GitHub replied, but not with the file the toolkit asked for."** GitHub
  answered with an error. Click **Update** again in a few minutes.
- **"This release isn't ready to install from the editor yet."** The release is
  out, but its update manifest or signature isn't on GitHub yet. Click
  **Update** later. If you didn't click, the badge keeps its links and checks
  again the next time you open the editor.
- **"This update failed its security check, so it won't install."** A trust
  document, the release's signature, its manifest or a download's redirect
  didn't pass the check. Your connection isn't the cause. This message has no
  GitHub or Asset Store button, because those would get you the release the
  check just refused. Wait for the next release. If the message comes back on
  the next one, report it privately as [`SECURITY.md`](../SECURITY.md)
  describes.
- **"Couldn't save update security data to *folder*."** The toolkit couldn't
  write a trust document to the folder the message names. Make that folder
  writable, then click **Update**.
- **"This update can't install here because your system doesn't set APPDATA"**
  (Windows) **or "HOME"** (macOS and Linux). The toolkit keeps its trust
  documents in your user data folder, and Godot finds that folder through this
  variable. Without it, the toolkit has nowhere to keep them, so it installs
  nothing. Set the variable where the editor gets its environment, then reopen
  the editor. This message has no **Update** button, since a click can't
  change it.

The first two messages and the security one end by saying the toolkit checks
again the next time you open the editor, unless you close the message.

**After you click Update.** If the download or the unpacking fails, the badge
says "Couldn't install:" and the reason. Click **Try again**.

**When the editor closes.** The update installs while the editor closes. If it
couldn't, the badge says why at the next start:

- **"When the editor last closed, the update didn't install:"** and a reason.
  Something got in the way that may clear by itself, such as a file another
  program held open. The update stays ready and tries again at every close.
- **"Godot MCP Toolkit *version* was not installed."** The last check before
  the install refused it. The line below names the reason, the version still
  installed and the install log. When the reason is that the update isn't
  signed by a key this toolkit trusts, the badge offers no download, and the
  toolkit offers the next release once it is published and checked.

If the reason is "the recovery plugin is not enabled", or the toolkit is off or
missing after an update, see
[The toolkit is off after an update](#the-toolkit-is-off-after-an-update).
Until the next update is ready, the version an update replaced also stays in
`addons/.godot_mcp_toolkit_update/backup-<version>/`, unless **Keep Backup** is
off.

A version that needs a newer Godot is never installed by the toolkit; the badge
names the Godot it needs.

To stop the toolkit from installing updates, set Project Settings → Mcp Toolkit →
Updates → Install Mode to `manual`, which also deletes an update waiting to
install. **Don't install** on the badge deletes that one update. An editor that
was killed (not closed) keeps a staged update and installs it at the next normal
close; disabling the plugin drops it.

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

### The toolkit is off after an update

An update installs while the editor closes: the toolkit moves the installed
version aside as a backup, then moves the new one in. If the editor is killed
between those two moves, `addons/godot_mcp_toolkit/` is missing at the next
start. If the new version doesn't load in your Godot, the editor turns the
toolkit off. Neither start can run the toolkit's own code, so a second, small
plugin handles these cases: the recovery plugin.

**The recovery plugin.** When an update is ready to install, the toolkit copies
the recovery plugin into `addons/.godot_mcp_toolkit_recovery/` and adds
`res://addons/.godot_mcp_toolkit_recovery/plugin.cfg` to the enabled plugins in
`project.godot`. Godot sorts that list when it saves it, so other entries may
change order. The folder's name starts with a dot, so the FileSystem dock and
the Plugins list don't show it, and its own `.gitignore` and `.p4ignore` keep
its files out of version control. The MCP file tools refuse paths in it, and
exports leave it out. The recovery plugin loads nothing from
`addons/godot_mcp_toolkit/`, so it runs even when the toolkit can't. It acts
only when the toolkit didn't start after an update, and never in a headless
editor or a command-line run that exports, imports, quits or runs a script. The
start that reports the update's result deletes the folder and the entry, and
turning the toolkit off deletes them too.

While the entry is in `project.godot`:

- If you commit `project.godot`, a teammate's editor, which has no such folder,
  prints `Addon 'res://addons/.godot_mcp_toolkit_recovery/plugin.cfg' failed to
  load. No directory found. Removing from enabled plugins.` The warning is
  harmless.
- If you revert `project.godot` after the update installed and before the next
  start, the recovery plugin doesn't run at that start. If the toolkit is off
  then, follow the [manual steps](#manual-steps) below.
- If `project.godot` can't be saved (it's read-only, or Perforce hasn't checked
  it out), the dock says "The update may not install when you close the editor:
  project.godot could not be saved." The update then doesn't install, and the
  next start says "When the editor last closed, the update didn't install: the
  recovery plugin is not enabled." Make `project.godot` writable and open the
  editor again: the toolkit adds the entry back, and the update installs at the
  next close.

**Its dialogs.** A dialog titled "Godot MCP Toolkit update" comes up a few
seconds after the editor opens. If the editor was killed during an update and
opened again at once, it can take up to about a minute. The rest of the editor
stays usable while it's open. **Restart now** restarts the editor. **Later**,
Esc or the close button leaves the toolkit off until you restart, and the next
start loads it. Turning other plugins on or off before then doesn't drop the
toolkit's entry.

- **"Version *X* did not load in Godot *Y*, so *Z* was put back."** The new
  version didn't load, for example because one of its scripts doesn't parse in
  your Godot. The recovery plugin moved it aside, moved the backup into
  `addons/godot_mcp_toolkit/` and deleted the version that failed. After the
  restart the dock says "Version *X* did not load in Godot *Y*, so *Z* was put
  back and is installed.", names this section and the install log, and doesn't
  offer *X* again until a newer version is out. No backup is left, since the
  backup is now the installed toolkit. Please report the failed version, with
  your Godot version and the install log, on
  [GitHub](https://github.com/NPGameDev/godot-mcp-toolkit/issues).
- **"The update to version *X* stopped partway, and it is now finished."** The
  editor was killed between the two moves. The new version was still whole in
  the update folder, matching the release's signed file list, so the recovery
  plugin moved it into place. After the restart the dock reports the update as
  installed.
- **"The update to version *X* stopped partway and could not be finished, so *Z*
  was put back."** The same kill, but the new version's files no longer matched
  the signed list, or couldn't be moved, so the recovery plugin moved the
  backup back in. After the restart the dock says what became of the update.
- **"Version *X* is installed, and Godot *Y* needs one more restart to load
  it."** In practice this is Godot 4.2. It starts plugins before its first file
  scan, using the script class list the previous version left, so an update
  that moves a script with a `class_name` can keep the new version from
  starting once. That scan fixes the list, and the restart loads the toolkit.
  Nothing was moved. This dialog comes once per version: if the start after it
  still finds the toolkit not running, the manual dialog below comes instead.

If a dialog ends with "project.godot could not be saved, so after the restart
turn the toolkit on in Project Settings > Plugins.", do that after the restart.

**The manual dialog.** "The toolkit update from *Z* to *X* left the toolkit off,
and the editor cannot set it right by itself." It points here, and moves
nothing. It comes when:

- the editor was killed between the two moves and neither the new version nor
  the backup could be moved into place;
- the new version didn't load and there is no backup to put back (deleted by
  hand), or putting it back failed partway;
- `addons/godot_mcp_toolkit/` holds a version other than the two the update
  names, or holds *Z* while the update records *X* as installed;
- on Godot 4.2, the start after "one more restart" still finds the toolkit not
  running. The Output panel names the script error that stops it.

Two cases get no dialog at all, and also need the manual steps: a new version
that loads but misbehaves, and a start where the recovery plugin wasn't there
(`project.godot` reverted, as above, or its folder deleted by `git clean`, as
below).

#### Manual steps

Close Godot and work in your file manager, since the editor hides both dot
folders. `install.log` in `addons/.godot_mcp_toolkit_update/` says what each
step of the update did.

1. If `addons/.godot_mcp_toolkit_update/` holds `backup-<version>/`, that is the
   whole version you had before the update. Move `addons/godot_mcp_toolkit/`, if
   it's there, out of the project or delete it, then move `backup-<version>/` to
   `addons/godot_mcp_toolkit/`.
2. If there is no backup, download the release zip of the version you want from
   [GitHub](https://github.com/NPGameDev/godot-mcp-toolkit/releases) and unzip
   it so its `addons/godot_mcp_toolkit/` replaces yours.
3. Delete `addons/.godot_mcp_toolkit_update/journal.json`, and any
   `broken-<version>/` folder beside it, so the next start doesn't take the
   half-finished update for one in progress.
4. Open the project. If the toolkit is off, turn it back on in **Project
   Settings → Plugins**. When a start finds the plugin's folder missing, Godot
   4.2 saves the plugin's removal from the enabled list; in testing, 4.3 and 4.7
   did not.

Once the toolkit runs with no update in progress, it deletes the recovery
plugin's folder and entry.

If `git clean -fdX` or `git clean -fdx` ran while the toolkit's folder was
missing, it deleted the update folder, with the backup and the new version in
it. It also deleted the recovery plugin's folder, so no dialog comes. Reinstall
the toolkit from the release zip.

### A cloud-synced project folder (OneDrive, Google Drive)

A sync client can hold the toolkit's files open while the editor closes and an
update moves the addon folder. The toolkit has been tested against a held file,
but not with a sync client running:

- If a held file stops the update before anything moves, the badge says "When
  the editor last closed, the update didn't install:" and the update tries
  again at the next close.
- If the toolkit is off or its folder is missing after the editor closed,
  follow
  [The toolkit is off after an update](#the-toolkit-is-off-after-an-update).
- On Windows, an addon folder that is a cloud placeholder counts as a link, so
  no update installs from the editor. Install updates by hand there.

To avoid the risk, pause syncing before you close the editor to install an
update.

## Still stuck?

Open an issue on
[GitHub](https://github.com/NPGameDev/godot-mcp-toolkit/issues) with your
Godot version, OS, the checklist results, and the relevant Output-log lines —
those five facts locate almost every problem.
