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
- `input_map_list`, a read-only tool in the `input_map` group, lists input
  actions with their events. By default it returns every project action and
  every built-in action whose events or deadzone differ from its default;
  `include_builtin: true` adds the unchanged built-in actions, and `name`
  returns one action. Each entry has `source` (`builtin` or `project`), the
  deadzone, the events and `can_revert`; a changed built-in action also has its
  `default`. `can_revert` follows the revert button in Project Settings > Input
  Map. A setting such as `input/jump.macos` is listed with `feature: "macos"`:
  Godot reads it as a feature-tag variant of `jump`. Needs the matching server
  release.
- `input_map_action` has a `revert` action: `{"action": "revert", "name":
  "ui_accept"}` puts a built-in action back to its default events and deadzone,
  and `project.godot` drops its line. It answers the action's `input_map_list`
  entry with `status: "reverted"`, or `"returned"` when the action already holds
  its default. A `project.godot` line that repeats the default's events is still
  removed, with `"reverted"`. A project action has no default, so `revert`
  refuses it, and `remove` on a built-in action now points at `revert`.
- Input events in `input_map_event` and `input_map_list` use one shape for
  reading and writing, so an event read from the list can be passed back to
  `unbind`. Every event has `class` (the engine class), and every event but an
  `unknown` one has `device`. A key has `key_kind` (`physical_keycode`, the
  default, `keycode` or `key_label`), so a built-in action's logical keys can be
  bound and unbound, plus
  `command_or_control` and, on Godot 4.3+, `location` (left or right). A mouse
  button has its modifiers, `command_or_control` and `double_click`. An event of
  another type is read as `{"type": "unknown", "class": …}`. A response carries
  `warnings` when a field was accepted but not applied: a mouse `pressed`, or a
  `location` on Godot 4.2.
- `scene_instantiate` now takes any file that loads as a scene, as an editor
  drop does: a `.scn`, or a 3D model imported as a scene (`.glb`, `.gltf`,
  `.dae`, `.blend`...). Before, it refused every file but a `.tscn`. A model
  imported as something else, such as an `.obj` imported as a mesh, is still
  refused. A model the editor hasn't imported yet fails with a message that
  says to run `editor_refresh` and retry. Thanks to @benfeather
  ([#39](https://github.com/NPGameDev/godot-mcp-toolkit/issues/39),
  [#40](https://github.com/NPGameDev/godot-mcp-toolkit/pull/40)).
- `GODOT_MCP_RUNTIME=0` (or `false`, `off`) keeps a run of your project off the
  runtime channel. Before, every run with the editor binary opened it, including
  a headless `--script` test runner, and took the project's runtime entry in the
  registry from the game the MCP tools had started. See "Keeping a run off the
  runtime channel" in the advanced configuration guide. An editor started with
  the variable set passes it to every game it launches, and a `game_start`
  re-probe names it in its hint. The repo's cold unit runner sets it outside CI.
  Reported and implemented by @benfeather
  ([#46](https://github.com/NPGameDev/godot-mcp-toolkit/issues/46),
  [#47](https://github.com/NPGameDev/godot-mcp-toolkit/pull/47)).
- `script_edit` accepts an `edits` array of `old_string`/`new_string`/`replace_all`
  objects and applies them in order in one call, each to the text the earlier
  ones leave. The file is written and checked once, with one undo entry, and
  `replacements` counts every span. If an edit is not found or matches more than
  once, nothing is written and the error names it (`edits[1]: …`). The single
  `old_string`/`new_string` form is unchanged. Needs the matching server
  release, whose schema declares `edits`. Thanks to @benfeather
  ([#44](https://github.com/NPGameDev/godot-mcp-toolkit/issues/44),
  [#50](https://github.com/NPGameDev/godot-mcp-toolkit/pull/50)).
- **Write .mcp.json** now pins the server to the version this toolkit was tested
  with (`@npgamedev/godot-mcp-server@<version>`), so a new server release no
  longer reaches every user, version warning included, on the day it ships. This
  is **Pinned** mode, the default. **Latest** mode runs the newest server on
  every start instead. The dock's `.mcp.json` panel shows which server the file
  runs and switches between the two modes, and the setup wizard's `.mcp.json`
  step offers the same choice. When a file the toolkit wrote no longer matches,
  the panel turns amber and offers to update it; a version set by hand gets a
  quiet offer to restore the recommended one. Nothing is rewritten without a
  confirmation. Restart your MCP client after a change. See "Server version
  (pin modes)" in the advanced configuration guide.
- The `mcp_toolkit/server/version` project setting picks the mode for the whole
  team: empty for Pinned, `latest` for Latest, or any npm version, range or tag,
  (you keep a custom value compatible yourself).
- The `mcp_toolkit/server/local_path` editor setting points **Write .mcp.json** at
  a local server build's `dist/index.js` on this machine (`node <path>` on every
  OS). It falls back to the `GODOT_MCP_DEV_SERVER_PATH` environment variable, and
  disabling the plugin offers to remove it with the toolkit's other editor
  settings.
- A pinned entry sets `npm_config_prefer_offline`, so `npx` starts the server it
  already downloaded without asking the npm registry. Latest, a range or a tag
  leaves it out, since it would stop `npx` from fetching a newer release.
- `scripts/release.sh` takes `--compatible-server X.Y.Z` (checked against npm) or
  `--keep-compatible-server`, and requires exactly one, so every toolkit release
  states the server version it pins.

### Fixed

- Writing `.mcp.json` from the dock, the Tools menu, the setup wizard or the
  enable prompt now keeps the other servers and top-level keys in a shared file.
  Before, the write replaced the whole file with the toolkit's entry. Only the
  toolkit's entry changes, and the file is re-serialized, so its formatting may
  change. A server that only has "godot-mcp" in its name is left alone,
  unless its entry runs the toolkit's server. A file
  that isn't valid JSON, or whose `mcpServers` isn't an object, is no longer
  overwritten: the toolkit says so and offers to open it, so you can fix or
  delete it first. The dock's "Fix .mcp.json" button is now "Open .mcp.json". The
  setup wizard's "Overwrite" button is now "Write .mcp.json" and asks before it
  changes an existing toolkit entry, as the dock already did; both ask only when
  the entry would actually change.
- After a project rename, **Regenerate Token** no longer leaves the MCP server
  unable to connect until the editor restarts.
- `node_manage` with `duplicate` now saves the copy's children. Before,
  `scene_get_tree` listed them, but the saved scene held the copy alone, because
  `Node.duplicate()` leaves the copied children with no owner. They also stay
  after an undo and a redo. The internals of an instanced sub-scene stay with
  the instance. Reported and fixed by @benfeather
  ([#37](https://github.com/NPGameDev/godot-mcp-toolkit/issues/37),
  [#38](https://github.com/NPGameDev/godot-mcp-toolkit/pull/38)).
- `resource_write` now saves a typed array property, such as `Array[String]`, as
  a typed array. Before, creating a resource from a script class (`type` naming
  a `class_name`) dropped the array with no warning, and other writes saved it
  untyped (`tags = ["x"]`). An element that doesn't fit the array's type now
  leaves the value unchanged, with a warning that names the element. A number
  with a fraction in an `Array[int]` is truncated, as it is for an `int`
  property, and a warning lists the elements that changed.
  Reported and fixed by @benfeather
  ([#41](https://github.com/NPGameDev/godot-mcp-toolkit/issues/41),
  [#42](https://github.com/NPGameDev/godot-mcp-toolkit/pull/42)).
- Nodes now run a script as it is on disk. `node_set_script` used to set the
  version the editor first loaded from that path, so after `script_edit`,
  `script_write` or another editor changed the file, a `@tool` script kept
  running its old code. Now `node_set_script` reloads a changed
  file, and a node that already has the script runs the new code too.
  `script_write` and `script_edit` reload the script themselves, and so do their
  undo and redo. The toolkit never loads a file that
  doesn't compile: when the file changed since the editor loaded it and does not
  compile, the `node_set_script` response carries `valid: false` and a hint that
  says so and points at `script_check`, and the nodes keep the code they had.
  The exception is Godot 4.4+ with an editor window, and 4.4 headless, where the
  editor still reloads a changed file by itself, broken or not. For a file changed outside the
  toolkit, the stale-instance hint on `node_call_method` now tells you to set the
  script again instead of relaunching the editor, and `script_write` no longer
  carries that hint. On Godot 4.2.2, an extension edit made with `script_write` or
  `script_edit` now applies live when it compiles, while one made outside the
  toolkit still needs an editor restart and `extensions_refresh` names it.
  None of this applies to Godot 4.2.0 and 4.2.1, where reloading a script in
  place can crash the editor (fixed in 4.2.2): there the toolkit reloads nothing,
  a changed script still needs an editor relaunch, `script_write` and
  `node_call_method` keep saying so, and every extension edit still needs a
  restart. When a GDScript extension's loaded source changes (a reload), the
  toolkit now registers its tools again, even for a body-only change.
  Reported and first fixed by @benfeather
  ([#43](https://github.com/NPGameDev/godot-mcp-toolkit/issues/43),
  [#45](https://github.com/NPGameDev/godot-mcp-toolkit/pull/45)).
- `input_map_event` with `bind` on a built-in action, such as `ui_left`, now keeps
  the events `project.godot` saves for it, or its default events when it saves
  none, joypad events included. Before, the bind saved the editor's keyboard-only
  copy of the action plus the new key, so a changed built-in lost its changes and
  an unchanged one lost its joypad events.
- `input_map_action` with `add` and no `deadzone` now uses the engine's default,
  as the editor's Add Action does: 0.2 from Godot 4.4, 0.5 before. Before, it used
  0.5 on every version.
- The `input_map_*` tools no longer change the editor's own input map. They read
  and write the project's settings, as Project Settings does.
- `input_map_event` now matches events the way Godot matches them when it checks
  an action. A mouse button's `pressed` no longer makes a second binding on
  `bind` or misses on `unbind`, and it is no longer stored or returned. A joypad
  motion matches on its axis and direction, not its exact value, so `0.5` and
  `1.0` on the same axis are one binding. An event with no `device` matches any
  device, and on Godot 4.7 a key or mouse event saved with device 0 by an older
  Godot matches one bound now. The logical keys of a built-in action, such as
  `ui_accept`'s Enter, can now be unbound with the event `input_map_list`
  returns.

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
