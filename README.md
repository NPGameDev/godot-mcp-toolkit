# Godot MCP Toolkit

[![CI](https://github.com/NPGameDev/godot-mcp-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/NPGameDev/godot-mcp-toolkit/actions/workflows/ci.yml)
![Godot 4.2+](https://img.shields.io/badge/Godot-4.2%2B-478CBF?logo=godotengine&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

AI-assisted Godot development through the [Model Context Protocol](https://modelcontextprotocol.io). Your AI coding assistant can create scenes, edit scripts, inspect nodes, run playtests, and more — directly inside the Godot editor.

> 📐 **[Architecture →](docs/architecture/README.md)** — how the toolkit is built: its subsystems, the editor↔runtime split, and the transport/contract surface. Also rendered at [npgamedev.github.io/godot-mcp-toolkit/architecture](https://npgamedev.github.io/godot-mcp-toolkit/architecture/).

## What it does

Godot MCP Toolkit turns the Godot 4.2+ editor into an MCP server. Any MCP-compatible AI coding assistant can connect and perform 55+ operations: creating scenes and nodes, reading and writing scripts, managing resources, running playtests, inspecting the class database, and controlling the editor — all without leaving the conversation.

Tested primarily with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Compatible with any MCP client that supports the Model Context Protocol.

## Quick start

### 1. Install the plugin

- **Godot AssetLib:** Inside the editor, go to AssetLib tab, search "Godot MCP Toolkit", Download, Install.
- **Manual:** Download from [GitHub Releases](https://github.com/NPGameDev/godot-mcp-toolkit/releases), extract into your project's `addons/` directory.

### 2. Enable the plugin

Project Settings &rarr; Plugins &rarr; **Godot MCP Toolkit** &rarr; check **Active**.

The dock panel appears at the bottom of the editor. The output log should show:

```
[MCP] WebSocket server listening on 127.0.0.1:6550
```

### 3. Install and configure the MCP server

```bash
npm install -g @npgamedev/godot-mcp-server
```

In your Godot project root, create `.mcp.json`:

```json
{
  "mcpServers": {
    "godot-mcp-toolkit": {
      "command": "npx",
      "args": ["-y", "@npgamedev/godot-mcp-server"]
    }
  }
}
```

<details>
<summary>Windows: use the cmd wrapper</summary>

```json
{
  "mcpServers": {
    "godot-mcp-toolkit": {
      "command": "cmd",
      "args": ["/c", "npx", "-y", "@npgamedev/godot-mcp-server"]
    }
  }
}
```

</details>

The plugin also offers **Project &rarr; Tools &rarr; MCP Toolkit &rarr; Write .mcp.json** to generate this file automatically.

### 4. Connect your AI assistant

Launch your MCP client from the project root. It discovers the plugin and authenticates automatically. The dock's peer count increments on connection.

## Architecture

```
MCP client ── stdio ──> @npgamedev/godot-mcp-server ── ws://127.0.0.1:6550 ──> godot-mcp-toolkit
(AI agent)               (Node.js, npm)                                         (this plugin)
```

The plugin runs a localhost-only WebSocket server inside the Godot editor. The companion [`godot-mcp-server`](https://github.com/NPGameDev/godot-mcp-server) npm package bridges your AI assistant (stdio/MCP) to the plugin (WebSocket). Two channels:

- **Editor channel** (port 6550) — operates on the edited scene via `EditorInterface`.
- **Runtime channel** (port 6570) — operates on the live `SceneTree` during playtests.

### Runtime channel (Mode B)

During playtests, the plugin injects an autoload node that opens a second WebSocket server on port 6570 (range 6570–6585). This enables runtime tools: inspecting live nodes, capturing game screenshots, simulating input, reading game logs, and evaluating GDScript expressions.

The runtime channel activates automatically when your AI assistant uses `game_start` with `wait_for_runtime: true` (the default). It shuts down when the playtest ends. Override the port with `GODOT_MCP_RUNTIME_PORT` in your `.mcp.json` env block.

Runtime tools are only available in debug builds (`OS.is_debug_build()` gated) and are never included in exported games.

## Dock UI

The bottom-panel dock provides at-a-glance status and full control:

| Section | What it shows |
|---------|---------------|
| **Server Status** | Listening address, connected peers, read-only-mode badge, last activity, runtime port during playtests |
| **Audit Log** | Enable/disable, size cap, view/clear the append-only tool-call log |
| **Security & Limits** | Regenerate auth token, configure script-read and WebSocket buffer caps |

The **Info / Help** button opens a panel showing connection details, the full registered tool list, plugin and Godot version info, and quick links to documentation and issues.

### Menu items

Available under **Project &rarr; Tools** and in the Command Palette (Ctrl+Shift+P):

- **Regenerate Token** — rotate the session auth token
- **Show Audit Log** — view last 100 audit entries
- **Open Project Settings** — jump to MCP Toolkit settings
- **Write .mcp.json** — generate the MCP client config file
- **Open .mcp.json** — open the MCP client config file

## Security

Security is a first-class design goal — not an afterthought.

- **Session auth** — A random 64-character hex token is generated on every plugin start. The MCP server reads it from disk automatically; unauthorized WebSocket connections are rejected.
- **Filesystem sandbox** — All file operations are restricted to `res://` by default. `FileGuard` blocks path traversal (`..`), absolute OS paths, and paths that resolve outside the boundary after lexical canonicalization, and denies the plugin's own source directory. (Canonicalization is lexical — not OS-symlink resolution.)
- **Read-only mode & per-tool control** — Set `GODOT_MCP_READ_ONLY=1` in `.mcp.json` and the MCP server hides every mutating tool (code execution, method calls, `user://` writes — all `destructiveHint` tools) from the agent: a server-side guarantee, independent of the editor. For finer control, block individual high-risk tools through your agent's own permission system (e.g. `.claude/settings.json` deny rules). See `docs/security-recommendations.md`.
- **Audit log** — Every tool call is logged with an ISO-8601 timestamp and parameter hash. Append-only, per-write flush for crash safety, configurable max size.
- **Response caps** — Script reads and WebSocket buffers are size-limited to prevent accidental exfiltration of large files.
- **Untrusted envelopes** — Content returned from the editor is wrapped in per-call nonce-tagged envelopes, mitigating prompt injection from file contents.
- **Localhost only** — The WebSocket server binds `127.0.0.1` exclusively. Never `0.0.0.0`.

> **Disclaimer:** We take security seriously and design every layer with defense-in-depth, but no software is immune to misuse or unforeseen vulnerabilities. This project is provided under the [MIT License](LICENSE) with no warranty. You are responsible for evaluating whether it meets your security requirements before use.

## Known limitations

### `claude -p` (pipe mode) does not support dynamic tool loading

**Affected:** `discover_tools` lazy-loading (Claude Code 2.1.104, confirmed 2026-05-06).

When Claude Code runs in pipe mode (`claude -p "..."`), it does not process `tools/list_changed` MCP notifications. Tools loaded dynamically via `discover_tools` are registered server-side but remain invisible to the agent — both direct calls and ToolSearch fail.

**Workaround:** No current workaround for pipe mode. Interactive `claude` sessions handle dynamic loading correctly.

## Tools

55+ tools across 13 domains. See the [server README](https://github.com/NPGameDev/godot-mcp-server#tool-reference) for the complete reference.

| Domain | Count | Examples |
|--------|-------|----------|
| Scene | 9 | Get tree, create/delete nodes, create/open/close scenes, instantiate, diff |
| Node | 5 | Get/set properties, list properties, set script, call method\* |
| Script | 5 | Read, write, read range, delete, check (structured diagnostics) |
| Editor | 9 | Save, screenshot, reload scripts, console output, wait for idle, project settings |
| Resource | 3 | Load, write/create, delete |
| Folder & File | 3 | Create/delete folders, delete files |
| Asset | 3 | List, dependencies, import (image/audio/font/3D) |
| Playtest | 2 | Start/stop game with runtime connection |
| Runtime | 6 | Screenshot, node inspection, game log, input simulation, animation, eval |
| Signals | 3 | List, connect/disconnect, emit |
| Animation | 2 | Add/remove keyframes, list keys |
| Input Map | 2 | Add/remove actions and events |
| User Data | 4 | Read/write/delete/list `user://` files |

### Headless mode compatibility

When Godot runs with `--headless`, the plugin loads and the WebSocket server starts normally. The vast majority of tools work without a display server — verified across Godot 4.2 through 4.6.

| Domain | Headless | Notes |
|--------|----------|-------|
| Script | ✅ | File I/O and `script_check` |
| Folder & File | ✅ | Pure filesystem operations |
| Resource | ✅ | Load, write, delete — file-based |
| Asset | ✅ | List, dependencies, import — uses EditorFileSystem metadata |
| User Data | ✅ | File I/O on `user://` paths |
| ClassDB | ✅ | Engine metadata — always available |
| Project Settings | ✅ | `project_get_settings`, `project_set_setting` |
| Editor (non-visual) | ✅ | Save, reload scripts, console, errors, wait for idle |
| Scene (file ops) | ✅ | `scene_create`, `scene_delete` — file-based |
| Scene (tree ops) | ✅ | `scene_open`, `scene_get_tree`, `scene_create_node`, `scene_delete_node`, `scene_instantiate`, `scene_diff`, `scene_close` |
| Node | ✅ | `node_get_property`, `node_set_property`, `node_get_property_list`, `node_set_script`, `node_call_method` |
| Signals | ✅ | `signal_list`, `signal_manage`, `signal_emit` |
| Animation / Input Map | ✅ | `animation_keyframe`, `animation_get_keys`, `input_map_action`, `input_map_event` |
| TileMap | ✅ | `tilemap_set_cells` |
| Playtest | ✅ | `game_start`, `game_stop` — game process launches without display |
| Screenshots | ❌ | `editor_screenshot`, `editor_screenshot_node` — returns `HEADLESS_UNSUPPORTED` (no viewport) |
| Runtime | ❌ | `runtime_*`, `game_eval`, `input_simulate` — require a running game with display |

✅ works &nbsp; ❌ requires display server

> **Tested:** Godot 4.2.0, 4.2.2, 4.3.0, 4.4.1, 4.5.0, 4.5.2, 4.6.2 on Windows. Screenshot tools detect headless mode and return a clear `HEADLESS_UNSUPPORTED` error code. See [COMPATIBILITY.md](COMPATIBILITY.md) for the full per-tool matrix.

## Read-only mode

For supervised environments (classrooms, CI, demos), set `GODOT_MCP_READ_ONLY=1` in your `.mcp.json` env to restrict the toolkit to read-only tools only. All mutating tools (create, delete, write, execute) are hidden from the AI agent. Remove `GODOT_MCP_READ_ONLY` from your `.mcp.json` and reconnect the MCP client to restore full access.

## Godot version support

**Minimum:** Godot 4.2 &nbsp; **Recommended:** Godot 4.5+

| Godot | Level | Notes |
|-------|-------|-------|
| 4.2 – 4.3 | Core | All tools work (undo history included); toast notifications fall back to the Output panel |
| 4.4 | Full UI | Toast notifications added; `scene_close` unavailable |
| 4.5+ | Full | All tools and UI features |

Future Godot versions (4.7+) are not blocked — the plugin uses runtime capability checks.

Full version matrix: [COMPATIBILITY.md](COMPATIBILITY.md)

## Enabling and disabling

- **Enable:** Project Settings &rarr; Plugins &rarr; "Godot MCP Toolkit" &rarr; check Active.
- **Disable:** Uncheck Active. A dialog offers to clean up the `.mcp.json` file.

The plugin runs only in the editor (`@tool` scripts) and is automatically stripped from exported builds by the bundled export plugin.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Upstream notices in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
