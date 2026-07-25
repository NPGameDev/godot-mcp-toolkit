# Changelog

All notable changes to the Godot MCP Toolkit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing has been released yet. This section collects everything headed for the
first public version.

### Added

- New command surface for 3D scenes and procedural content: 3D primitives,
  environment, lights, and cameras; AnimationTree state-machine and blend-tree
  editing; project input-layer name management; Path2D curve editing;
  auto-generated collision shapes from a sprite's texture; inherited-scene
  creation; procedural gradient, curve, and noise resources; audio-bus editing;
  SpriteFrames animation tools; GPU particle systems with ready-made presets;
  and navigation-polygon editing.
- Tileset authoring: create a tileset from a spritesheet with auto-generated
  collision, then edit per-tile collision, terrain, navigation, occlusion,
  custom data, animation, and probability across multiple sources.
- Extension API for distributable third-party addons: register your own MCP
  commands in GDScript with rich metadata, hot-reload them without restarting
  the editor, set per-tool timeouts, and cancel long-running calls. C#/.NET
  projects are fully supported. A catalog dialog in the editor discovers
  installed extensions.
- In-editor GDScript debugger integration: set breakpoints, inspect debug
  state, read crash diagnostics from a captured error buffer, and detect an
  external script editor.
- Per-project language-server (LSP) discovery, so LSP-backed tools reach the
  right project's editor and the dock shows the true LSP status.
- `script_edit` for targeted edits to a script instead of rewriting the whole
  file.
- `scene_spatial_map` reports node positions and bounds, and the
  `texture_generate` and `sound_generate` tools produce placeholder assets while
  you block out a scene.
- `input_simulate` accepts a batch of input events (an `events` array with a
  `"click"` shorthand), reports per-event results, and adds `delay_before_ms` /
  `delay_after_ms` timing and a `summary` option. It also accepts a single event
  directly, not only an array, and gains a `send_text` event for typing into a
  focused text field.
- `scene_create`, `script_write`, and `resource_write` create any missing parent
  directories on their own, and report `dirs_created` only when that happened —
  no more separate folder-creation calls first.
- Signal-connection inspection and management.
- Structured required-parameter validation across every command, with
  context-specific hints when a parameter is missing.
- Configurable editor and runtime ports — pin a single port or give a range —
  through environment variables, with a clear message when a port cannot bind.
- Exports automatically strip GDScript source and the project's `.mcp.json` from
  shipped builds, so neither the plugin's code nor its auth tokens travel with a
  release.
- Concurrent human and AI editing is validated and documented as a supported
  workflow.
- An opt-in setting keeps the editor responsive while it is unfocused, with a
  dock indicator showing when it is active. This replaces an earlier, undocumented
  global throttle.
- macOS setup guidance in both the onboarding wizard and the dock, and a
  `.mcp.json` written with correct macOS paths.
- The editor's Tools menu gains an "MCP Toolkit" submenu for quick access to
  plugin actions.
- Godot 4.7 is supported. On Godot 4.7, `scene_close` reports any unsaved
  changes it discarded.
- When a target already exists, tools such as `scene_create_node`,
  `scene_instantiate`, and `resource_write` disclose any arguments they silently
  dropped instead of ignoring them quietly.
- The companion Claude Code skill `godot-mcp-toolkit` ships inside the addon
  (`addons/godot_mcp_toolkit/CompanionSkills/godot-mcp-toolkit/`) for guidance on
  tool selection, workflow patterns, and error recovery.
- A startup line in the Output panel naming the plugin version and author when
  the plugin loads.

### Changed

- Code execution is now the `execute_code` tool (previously `game_eval`). It runs
  in the editor or in the running game, and returns clearer errors for
  statement-only input and for globals that are not reachable from where the code
  runs.
- The `editor_reload_scripts` tool is renamed `editor_refresh`. On a headless
  editor it waits for the filesystem scan to finish before returning, so a script
  reload is reliable there.
- Nine tool parameters were renamed for consistency (a one-time cleanup before
  the first release, with no backward-compatible aliases): `tilemap_path` to
  `node_path`; `path` to `file_path` or `texture_path` depending on the tool;
  `target_parent` to `parent_path`; `max_results` to `limit`; `depth` to
  `max_depth`; `property_name` to `property`; and the folder tools' `folder_path`
  to `path`.
- The tool surface is one mode plus an orthogonal read-only switch. The earlier
  profile system (Minimal / Standard / Power User / Custom, and the
  `GODOT_MCP_PROFILE` setting) is gone; a small always-on core is exposed on
  connect and the rest of the tools are loaded on demand. Read-only access is a
  separate switch — the `GODOT_MCP_READ_ONLY=1` environment variable and a
  matching dock toggle — that hides every mutating tool.
- The `.mcp.json` file is managed for you: the plugin creates it when needed,
  offers a one-click fix, keeps a live status badge, and no longer writes stale
  environment variables into it.
- Per-project data (auth tokens, the sidecar state file, the audit log) lives in
  a deterministic per-project folder derived from the project path, so multiple
  editors and worktrees no longer collide.
- The dock is a scrollable layout with collapsible sections for status, limits,
  the audit log, and `.mcp.json` health.
- Tool errors and hints are substantially more specific — for example, why a
  readback came back empty, when a call reached the wrong editor instance, when a
  script is not attached, when a class does not match, and when an autoload is
  involved.
- Screenshot and image responses either inline a downscaled image or save the
  full image to disk, selected by an `image_detail` parameter. A bad or minimized
  viewport is detected and reported instead of returning a blank image.
- Scene queries, ClassDB lookups, and script and save reads share one pagination
  envelope (`has_more`, `returned`, and an offset), with configurable size caps.
- The onboarding wizard promotes its Project Settings pointer to a first-class
  step.
- Read-only-mode errors point you to reconnect the client, not restart the
  editor.
- On Godot 4.2 through 4.4, features that depend on newer editor APIs (signal
  listing, AnimationTree state lists, console-level filtering) degrade
  gracefully instead of failing.
- The minimum Node.js version is 22.
- `editor_get_console` gains a `level_filter`, replacing the separate
  `editor.get_errors` tool.

### Fixed

- The Godot 4.3 editor no longer crashes intermittently when a node that was
  described a moment earlier is deleted (a workaround for an engine bug).
- Batch operations report success or failure per entry instead of silently
  dropping the ones that failed.
- Property sets reject a wrong-type value instead of coercing it, and the
  reserved `groups` property is protected.
- Oversized WebSocket responses are rejected with a clear error rather than
  failing opaquely.
- `game_start` gives a clear "no main scene" error when the project has none set.
- Log reading distinguishes a transient file lock from a missing log, and reads
  the current session from its start.
- `folder_delete` reports correct counts and closes the script tabs of the files
  it deleted.
- Node.js detection uses the login shell on macOS and Linux, and shows a PATH
  hint on Windows.
- The sidecar state file recovers on its own, retrying after the project's
  `.godot/` folder is deleted.

### Removed

- The profile system (Minimal / Standard / Power User / Custom profiles, the
  `GODOT_MCP_PROFILE` and `GODOT_MCP_CUSTOM_TOOLS` settings, and the
  `enable_tool_group` tool). The single tool surface plus the
  `GODOT_MCP_READ_ONLY=1` switch replaces it; tool groups are surfaced and
  activated through the `discover_tools` meta-tool.
- The `editor.get_errors` tool — use `editor_get_console` with its `level_filter`.
