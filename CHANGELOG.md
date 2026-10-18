# Changelog

All notable changes to the Godot MCP Toolkit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `input_map_action` has a `rename` action: `{"action": "rename", "name": "old",
  "new_name": "new"}` moves an input action saved in `project.godot` to the new
  name with its events and deadzone, and keeps its place in the Input Map list.
  Before, a rename took `add`, one `bind` per event and `remove`. A built-in action
  can't be renamed, and an action can't take its own name or a name already in
  use, including a built-in action's. Scripts and scenes that use the old name
  aren't changed, the same as after a rename in Project Settings. Needs the
  matching server release, whose schema accepts `rename` and `new_name`.
  Thanks to @benfeather
  ([#18](https://github.com/NPGameDev/godot-mcp-toolkit/issues/18),
  [#19](https://github.com/NPGameDev/godot-mcp-toolkit/pull/19)).
- `GODOT_MCP_RUNTIME=0` keeps the runtime server out of a run of your project.
  Before, every run with the editor binary started it, including a headless
  `--script` test runner, and took the project's runtime entry in the registry
  from the game the MCP tools had started. See "Keeping the runtime server out of
  a run" in the advanced configuration guide.

### Fixed

- After a project rename, **Regenerate Token** no longer leaves the MCP server
  unable to connect until the editor restarts.

## [1.0.4] - 2026-10-14

### Fixed

- A response limit set through an environment variable in `.mcp.json`
  (`GODOT_MCP_SCRIPT_READ_LIMIT` or `GODOT_MCP_WS_BUFFER_LIMIT`) is no longer
  written into `project.godot` when the project is saved. The dock keeps showing
  the project's own value and adds a line under the field naming the variable in
  use. If an earlier version already saved an environment value into
  `project.godot`, it now counts as the project value: reset it in Project
  Settings.
- `mcp_toolkit/concurrency/scene_lease_ttl_ms` now appears in Project Settings,
  as the docs said.
- The dock's LSP line now follows a change to the LSP host or port in Editor
  Settings.
- The Info dialog now shows the read-only state the running MCP server
  applies, as the dock's badge does. If `.mcp.json` has changed since the
  server started, it adds a line saying the change applies when the MCP client
  restarts.
- The dock's collapsible sections no longer pad themselves with empty space; the
  spare height sits below the last section, and a dock too short for its
  content scrolls.
- `resource_write` no longer saves an `int` property of a script resource as a
  float (`price = 4.0`) when it updates an existing file and the script isn't
  `@tool`. A value with a fraction, such as `4.5`, is saved as `4` in any `int`
  property, whether the file is created or updated, and the response includes a
  warning. Reported and fixed by @benfeather
  ([#10](https://github.com/NPGameDev/godot-mcp-toolkit/issues/10),
  [#11](https://github.com/NPGameDev/godot-mcp-toolkit/pull/11)).
- `resource_write` now warns that a key naming only an inspector group,
  subgroup or category (such as `Albedo` on a `StandardMaterial3D`) is an
  unknown property. Before, it dropped the value with no warning.
- `scene_instantiate` no longer copies the instanced scene's root class
  (`type=`), root script, other changed root properties and groups into your
  scene when you save it. They stayed pinned on the instance, so swapping or
  removing the instanced scene's root script didn't reach it. Reopening and
  saving your scene cleared the pinned values only while the instanced scene's
  root still matched them. The instance now saves the way the editor saves a
  scene you drop in. Reported and fixed by @benfeather
  ([#12](https://github.com/NPGameDev/godot-mcp-toolkit/issues/12),
  [#13](https://github.com/NPGameDev/godot-mcp-toolkit/pull/13)).
- `input_map_action` and `input_map_event` now see the input actions your project
  adds in `project.godot`. Before, `bind`, `unbind` and `remove` answered
  `NOT_FOUND` for them, and `add` answered `created` and saved the action again
  with no events, which wiped its bindings. Each call reads the saved action
  again, so the next call keeps a change you make to it in Project Settings,
  including a rename or a delete. Reported and fixed by @benfeather
  ([#14](https://github.com/NPGameDev/godot-mcp-toolkit/issues/14),
  [#15](https://github.com/NPGameDev/godot-mcp-toolkit/pull/15)).
- `input_map_action` now refuses to remove any built-in action, such as
  `ui_select`. Before, it checked a fixed list of names that missed some built-in
  actions on every supported Godot version.
- `script_check`, `script_write` and `script_edit` no longer delete a script's
  `class_name` from the copy they check: they rename it and run Godot's own
  `class_name` checks on the real name. This ends the false compile errors for
  the one-line form `class_name Player extends Node`, for `@tool` or
  `@abstract` before `class_name` on the same line, or for a script that
  uses `self` as its own class (`return self` from a function typed
  `-> Player`, or `self` stored in a `static var instance: Player`). A
  `class_name` that hides an autoload, another script's class, an engine
  class (an abstract one only from Godot 4.4) or a built-in type is now
  reported, with its line, on every Godot version. Passing `self` to another
  script's function typed with the class still reports a false error, and
  `lsp_diagnostics` gives the real result. Reported and first fixed by
  @benfeather ([#16](https://github.com/NPGameDev/godot-mcp-toolkit/issues/16),
  [#17](https://github.com/NPGameDev/godot-mcp-toolkit/pull/17)).
- `node_set_property` (single and batch), `scene_instantiate` (the `properties`
  of each instance) and `node_manage`'s `duplicate` no longer save an `int`
  property as a float (`hp = 100.0`) on a node whose script isn't `@tool`.
  `project_set_setting` no longer saves an `int` setting as a float either
  (`window/size/viewport_width=1153.0`); a custom setting counts as `int` when
  it currently holds an int. A value with a fraction, such as
  `100.5`, is stored as `100`, and the response includes a warning
  ([#26](https://github.com/NPGameDev/godot-mcp-toolkit/issues/26)).
- Batch `node_set_property` no longer tells you to retry with `make_unique` when
  a value was only adjusted to fit, such as `3.5` on an `int` property.
- The registry no longer logs `ERROR: Thread <pid> exited with errno: 10` on
  Godot 4.6 (Linux, or macOS after an editor quits without cleaning up) or, on
  Godot 4.7, `The process <pid> does not exist or is not a child of the calling
  process.` The registry asked Godot whether other editors were still running,
  and on Windows and Linux Godot can only answer that for processes it started
  itself. This also let two editors update the registry at the same time, and
  opening a project that was already open in another editor gave no warning.
  Now the registry lock waits while another editor holds it, and a second
  editor on the same project gets a warning. When an editor that didn't exit
  cleanly left its entry behind and the new editor takes its port, the registry
  replaces it and prints an info line instead of the warning. Reported and
  fixed by @benfeather
  ([#28](https://github.com/NPGameDev/godot-mcp-toolkit/issues/28),
  [#29](https://github.com/NPGameDev/godot-mcp-toolkit/pull/29)).

### Removed

- The `mcp_toolkit/limits/env_override_note` setting. The dock now shows which
  limits an environment variable overrides. A copy stored in `project.godot` is
  dropped the next time project settings are saved.
- Two settings that never had an effect: the
  `mcp_toolkit/personal/dock_default_visible` editor setting and the
  `mcp_toolkit/internal/bootstrap_complete` project setting. Disabling the plugin
  still offers to erase an old copy of the editor setting.

## [1.0.3] - 2026-10-05

### Fixed

- The dock's response-limit and audit-log controls now follow edits made in
  Project Settings. Before, they kept showing the old value until the plugin
  reloaded, so adjusting one of them in the dock started from that stale value and
  could overwrite your edit. Project Settings now also limits these values to the
  same ranges the dock uses.
- On Windows, opening the editor without Node.js installed no longer prints a red
  "Could not create child process" error in the Output panel, or, on Godot 4.5 and
  later, a script backtrace in the console. The dock's "Node.js not found" warning
  still appears.

## [1.0.2] - 2026-09-21

### Fixed

- The plugin no longer writes its status readout (Node.js version, `.mcp.json`
  presence, read-only mode) into `ProjectSettings`. That readout describes the
  machine the editor runs on, so storing it put a per-developer value into
  `project.godot`, and the committed file kept changing depending on who opened
  the project last. The dock still shows the same status live. Reported and
  fixed by @bclarksoftware
  ([#2](https://github.com/NPGameDev/godot-mcp-toolkit/pull/2)).
- If an earlier version already stored `mcp_toolkit/status` in your
  `project.godot`, 1.0.2 clears it in memory when the plugin loads, so the key is
  dropped the next time project settings are saved.

## [1.0.1] - 2026-09-21

Companion release for **server 1.0.1**, which fixes the MCP server process outliving its
client and spinning a CPU core at 100% after the client exits without a signal — reported
and first fixed by @nickkurkan
([server issue #2](https://github.com/NPGameDev/godot-mcp-server/issues/2); details in the
server's own changelog). Projects whose `.mcp.json` launches the server unpinned pick it
up the next time your MCP client starts and npx resolves the package. If you ran server
1.0.0, check once for leftover `node` processes running `godot-mcp-server` and end them
(`pgrep -fl godot-mcp-server` on macOS/Linux, Task Manager on Windows).

### Changed

- The connect-time version check no longer warns when the plugin and the server differ
  only by a patch version (for example plugin 1.0.0 with server 1.0.1). A minor-version
  difference still warns; a major-version difference still errors.

## [1.0.0] - 2026-07-27

The first public release of the Godot MCP Toolkit.

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
