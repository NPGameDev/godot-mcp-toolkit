# Godot MCP Toolkit

A Godot 4.2+ editor plugin that runs a localhost WebSocket server so an AI
coding assistant — Claude Code, or any MCP-compatible client — can create
scenes, edit scripts, inspect nodes, and run playtests inside your editor.
The plugin is half the stack: the companion npm package
`@npgamedev/godot-mcp-server` is the bridge your assistant actually talks to.

Everything runs locally. Nothing leaves your machine.

## Quick start

1. **Enable the plugin:** Project Settings → Plugins → **Godot MCP Toolkit** →
   check **Active**. The MCP dock appears in the bottom panel and the Output
   log prints `[MCPServer] listening on 127.0.0.1:6550` (the port may land
   anywhere in 6550–6560; the dock names the live one). That line is the
   plugin's own WebSocket server inside the editor. The npm bridge is a
   separate process your MCP client starts later, and it dials this port.
2. **Write the client config:** **Project → Tools → MCP Toolkit →
   Write .mcp.json** creates the config at your project root. It runs the
   bridge through `npx -y @npgamedev/godot-mcp-server`, which fetches it on
   first connect, so there is no install step (Node.js 22 or newer required).
   If you would rather keep a fixed copy on the machine,
   `npm install -g @npgamedev/godot-mcp-server` works too. (Manual
   alternative: copy `addons/godot_mcp_toolkit/.mcp.json.template` to your
   project root and rename it `.mcp.json`.)
3. **Connect:** launch your MCP client from the project root. It discovers
   the plugin and authenticates automatically; the dock's peer count
   increments on connection.

If a step misfires, the troubleshooting guide has a 60-second checklist and a
connectivity probe:
<https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md>

## Where things are

- **The dock** (bottom panel, "MCP") — server status and the bound port,
  connected peers, the read-only toggle, audit-log viewer, response limits,
  and `.mcp.json` health with a one-click fix.
- **Project → Tools → MCP Toolkit** — quick actions: write or open
  `.mcp.json`, regenerate the auth token, show the audit log, open the
  plugin's Project Settings. Also in the Command Palette (Ctrl+Shift+P).
- **Info / Help** (button in the dock) — connection details, the registered
  tool list, version compatibility, multi-instance guidance, and links,
  including a button that opens the shipped compatibility guide.

## Read-only mode

For supervised environments (classrooms, CI, demos), flip the dock's
read-only toggle (or set `GODOT_MCP_READ_ONLY=1` in the `.mcp.json` env
block). Every mutating tool is hidden from the agent. Turn it off and
reconnect the client to restore full access — the tool list is decided at
connect time.

## Documentation

Shipped with this addon, in `addons/godot_mcp_toolkit/docs/`:

- [compatibility.md](docs/compatibility.md) — supported Godot versions,
  per-tool and headless matrices, degraded behavior, the C# (.NET editor)
  requirement, export stripping, and how to disable the plugin safely.
- [security-recommendations.md](docs/security-recommendations.md) — the
  security model and recommended client-side permission rules.
- [extending.md](docs/extending.md) — register your own MCP tools in
  GDScript (C# supported), with hot-reload, timeouts, and cancellation.
- [multi-instance.md](docs/multi-instance.md) — several editors or git
  worktrees side by side.
- [advanced_configuration.md](docs/advanced_configuration.md) — ports,
  limits, environment variables, macOS specifics.

The addon also bundles [agent skills](docs/companion-skills.md) — a workflow
skill and an extension-authoring skill — in
`addons/godot_mcp_toolkit/CompanionSkills/`; copy a skill folder into your
client's skills directory to use them.

On the web:

- Tool reference (every tool and operation, generated from the code):
  <https://github.com/NPGameDev/godot-mcp-server/blob/main/docs/tool-reference/README.md>
- Toolkit repository, issues, and full documentation:
  <https://github.com/NPGameDev/godot-mcp-toolkit>

## Uninstalling

Disable via Project Settings → Plugins (a dialog offers to clean up
`.mcp.json`), or remove the addon folder. If you delete the folder while the
plugin is still enabled, the cleanup step cannot run — delete `.mcp.json`
from your project root yourself. The shipped compatibility guide covers why
you should not disable the plugin by hand-editing `project.godot`.

## License

MIT: the full text travels with the addon in [LICENSE](LICENSE). Third-party
attributions are in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).

## Trademarks

Godot and the Godot logo are trademarks of the Godot Foundation. This add-on is
an independent community project with no affiliation with or endorsement from the
Foundation, and it is not an official Godot product. The name describes what the
add-on runs on: the Godot Engine.
