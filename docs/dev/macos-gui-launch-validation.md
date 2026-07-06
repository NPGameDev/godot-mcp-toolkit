# macOS GUI-launch validation

Maintainer methodology for the one check that cannot run in CI: does a **GUI-launched**
MCP client (started from Finder/Dock, not a terminal) connect to the toolkit on macOS and
round-trip a tool call? CI runs headless on hosted runners and never exercises a desktop
client spawned under `launchd`, so a real Mac — **Intel or Apple Silicon** — is the only way
to cover this path. Run it once per release (see `release-checklist.md`).

## What the current model is (read this first)

The toolkit writes a **bare `npx -y @npgamedev/godot-mcp-server`** command into `.mcp.json`
on macOS — the same shape as Linux. There is **no** launchd/PATH machinery: no
toolkit-resolved absolute `node` path, no `env.PATH` backstop, no rewrite of `.mcp.json` on
editor start, and no macOS "can't find Node" dock panel. Modern desktop MCP clients
(Claude Desktop, VS Code, Cursor) capture the login shell's environment before they spawn
the server, so they resolve a bare `npx` to a version-manager Node themselves. This
validation confirms that holds on the target Mac's Node setup — it is **not** verifying any
macOS-specific config the toolkit no longer emits. Background: ADR 0018.

**No third-party runtime dependencies.** The toolkit is GDScript shipped under `addons/`; it
vendors no third-party code. Part of every run is confirming that stays true (see the
checklist).

## Prerequisites

- A **Mac** (Intel or Apple Silicon).
- **Node 20+.** The published server declares `engines.node >= 22`, so use **Node 22+** to
  match the shipped artifact. Any install method is fine (nvm, fnm, volta, Homebrew,
  nodejs.org installer) — the manager matters for the gotchas below.
- A **Godot editor build** for the version under test (4.2–4.7). Use a .NET/mono build only
  if the project under test is C#.
- A **GUI MCP client**. **Claude Desktop** is the primary, most-representative client; VS Code
  or Cursor work as cross-checks (same `resolveShellEnv` mechanism).
- The **two impl repos on the Mac**. Clone read-only (a short-lived, read-only fine-grained
  PAT in the clone URL avoids an interactive git login for private repos), then build the
  server if you are testing a local dev build:
  ```bash
  git clone https://<TOKEN>@github.com/NPGameDev/godot-mcp-toolkit.git
  git clone https://<TOKEN>@github.com/NPGameDev/godot-mcp-server.git
  ( cd godot-mcp-server && npm ci && npm run build )   # dist/ is what a client spawns
  ```
  The Mac is a **validate-only** station — it never authors or commits. Pull for updates;
  revoke the PAT and delete the clones on teardown.

## Procedure

1. **Enable the plugin.** Open the toolkit project (or any project with
   `addons/godot_mcp_toolkit/` copied in) in the Godot editor. **Project → Project Settings →
   Plugins →** enable **Godot MCP Toolkit**. The MCP Toolkit dock appears and its status row
   shows the editor **listening on port 6550**.
2. **Write the config.** In the dock, click **Write .mcp.json**. Confirm it wrote a bare-`npx`
   command at the project root:
   ```bash
   cat .mcp.json    # command should be: npx -y @npgamedev/godot-mcp-server (no absolute path, no env.PATH)
   ```
   To point at a local server build instead, set `GODOT_MCP_DEV_SERVER_PATH` to your built
   `dist/index.js` before clicking Write — the toolkit then emits a `node <that path>` command.
3. **GUI-launch the client.** Start the MCP client from **Finder/Dock** (not a terminal) so it
   inherits the `launchd` environment — this is the path CI can't reach. Point it at the
   project whose `.mcp.json` you just wrote.
4. **Verify connect + round-trip.**
   - The client's MCP log shows a **clean connect** — no `spawn npx ENOENT`.
     Claude Desktop: `~/Library/Logs/Claude/mcp*.log`.
   - The tool list populates (the eager + meta startup surface).
   - `discover_tools` loads a group, and a read-only tool round-trips (e.g. list the scene
     tree or query a ClassDB class) with a valid response.
   - The dock's **peer-count status row shows 1 connected peer**.
5. **Confirm `.mcp.json` is stable.** Close and reopen the Godot editor. `.mcp.json` must be
   **unchanged** — the editor no longer rewrites it on start.

The `claude` CLI from the project root (a terminal launch, dev-form or bare-`npx` `.mcp.json`)
is a valid complementary E2E check, but the **Finder/Dock client launch in step 3 is the
load-bearing one** — it is the only path that exercises the `launchd` environment.

## What PASS looks like

- GUI-launched client connects with **no `ENOENT`**; tool list populated; `discover_tools` and
  a read tool round-trip cleanly.
- Opening the editor does **not** mutate `.mcp.json`.
- Dock peer-count row reflects the live connection.
- No third-party runtime code ships in `addons/`.

## Mac-specific gotchas (from the live runs)

- **Client PATH augmentation hides the interesting case.** Claude Desktop already augments
  `PATH` for **nvm** and **Homebrew**, so those "just work" and are only a control — they don't
  prove the general case. To exercise a manager the client does **not** special-case, test with
  **fnm**, **volta**, or a **keg-only** `node@22`. If a bare-`npx` GUI launch connects with one
  of those, the shell-env capture is working.
- **Login shell vs interactive shell.** A Finder/Dock launch reads a **login** shell
  (`~/.zprofile`), not `~/.zshrc`. If a version manager's init lives **only** in `~/.zshrc`, a
  GUI launch won't see Node — add the init to `~/.zprofile` too.
- **Fish / Nushell** login shells are non-POSIX; a shell-env probe degrades cleanly to bare
  `npx`. Recovery is the nodejs.org installer (lands on the default `PATH`) or an explicit
  `env.PATH`.
- **Never hard-pin an ephemeral path.** `fnm_multishells/…` paths are per-session symlinks that
  vanish across reboot/GC. Pinning one can *override* a capable client's own working resolution
  — this is exactly why the absolute-path emission was removed. Bare `npx` tracks the current
  Node.
- **Keep shell init silent.** A `~/.zprofile` that **echoes/prints** can corrupt the server's
  JSON-RPC handshake over stdio. If a handshake looks garbled, check for banner output in the
  login shell. (Bare `npx`/`node` spawn directly with no wrapper shell, so this only bites if
  your own dotfiles print.)
- **The editor must be listening.** No connection is possible unless the Godot editor is open
  with the plugin enabled (dock shows listening on 6550).

## Teardown

If you set up a throwaway validation environment (PAT-checkout clones, a client MCP entry
added just for this, a deliberately unlinked node baseline), restore the Mac afterward: revoke
the PAT, delete the clones, remove the client MCP entry you added, and confirm the node
landscape resolves again:

```bash
which -a node npm npx
node -v; npm -v; npx -v
```
