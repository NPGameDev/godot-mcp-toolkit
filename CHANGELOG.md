# Changelog

All notable changes to the Godot MCP Toolkit are documented in this file.

This changelog is auto-generated from [Conventional Commits](https://www.conventionalcommits.org/).

## Features

- feat(plugin): websocket server on 127.0.0.1:6505 with echo command (`b722a98`)
- feat(plugin): scene tree, node create/delete, property get/set (`aa6bf5a`)
- feat(plugin): script read/write, get_errors, save_scene, screenshot (`392b210`)
- feat(plugin): optional save_path on editor.screenshot (`4e14e91`)
- feat(config): LICENSE + ATTRIBUTIONS + CLAUDE.md + DISTRIBUTION.md + plugin release tooling (`6825cb4`)
- feat(plugin): tier 1 — undo-aware script write, reload scripts, scene open, project settings (`229bb1e`)
- feat(plugin): tier 2 runtime autoload — screenshot, node state, debugger log (mode b) (`293f978`)
- feat(plugin): tier 3 — signal.*, resource.load, node.get_property_list (editor + runtime) (`0ce28b4`)
- feat(plugin): tier 3 runtime — input.simulate, animation_player.control, scene.diff, gated game.eval (`9e99345`)
- feat(plugin): re-listen loop for editor + runtime sockets on socket error (`76cdf95`)
- feat(plugin): scene.create/delete + script.delete + idempotency audit (`1e435c1`)
- feat(plugin): resource.create/save/delete + folder.create/delete + shader allowlist (`78e1a76`)
- feat(plugin): game.start/stop + scene.instantiate + node.call_method + _coerce_value Resource/typed-dict support (new codes: ALREADY_PLAYING, INVALID_METHOD) (`a4c184f`)
- feat(plugin): project.set_setting + input_map.* + animation.* + tilemap.set_cells + editor.screenshot_node + _coerce_value transform/int-vector extensions (`d9d9a33`)
- feat(plugin): asset.list/get_dependencies + editor.get_console + editor.get_errors stub replacement (new codes: FILESYSTEM_NOT_READY, LOG_UNAVAILABLE) (`481b7d8`)
- feat(plugin): asset.import (filesystem copy + base64 + if_exists + scan-wait) + editor.wait_for_idle (scan-polling with timeout) (`902f1a3`)
- feat(plugin): scene.close (Godot 4.5 EditorInterface.close_scene) + probe teardown + gitignore cleanup (`65b871a`)
- feat(plugin): scene.create_node global class resolution + node.set_script (attach/detach with @export property return) (`9693bef`)
- feat(plugin): file.delete (generic res:// file removal with .import/.uid companion cleanup) (`aa6423d`)
- feat(plugin): loopback bind audit, session-token auth, FileGuard, untrusted envelopes (`711fd6b`)
- feat(plugin): FeatureGate system with dual/single-gate logic and ProjectSettings integration (`a2cdabd`)
- feat(plugin): save.read/write/delete/list + FileGuard.resolve_safe_user + read_user_scope feature-gate + whitelist config (`40fc31a`)
- feat(plugin): secret scrubber, audit log, export strip, 256KB cap, 1MB WS buffers (`d30abb1`)
- feat(plugin-ui): dock, menu items, command palette, .mcp.json sync, power user mode (`31afd8a`)
- feat(plugin): iter 22 — merge 5 tool pairs, progressive detail params, profile display (`1b877a3`)
- feat(plugin): dynamic port allocation (editor + runtime) + system-wide project registry (`e426a3f`)
- feat(plugin): per-worktree token path + registry entry disambiguation (`0ff17f3`)
- feat(plugin): user_commands auto-loader for GDScript extensions (`dcab10f`)
- feat(plugin): classdb.get_info — introspect properties/methods/signals/constants for engine + user classes (`8c6e86e`)
- feat(plugin): classdb.search — discover classes by inheritance + name pattern (`cd15763`)
- feat(plugin): script.check — structured GDScript diagnostics (errors + warnings with line numbers) (`2e3d5b1`)

## Bug Fixes

- fix(plugin): align scaffold to Godot 4.4 (bump features + commit .uid files) (`8601a70`)
- fix(plugin): editor-safe scene.delete_node + screenshot absolute_path (`e085b4d`)
- fix(plugin): use UndoRedo for delete_node; inline base64 for screenshot (`a7074b7`)
- fix(plugin): inert-autoload in editor/release, no queue_free (resolves remove_child(null) on disable) (`154c451`)
- fix(plugin): discard stale TCPServer on listen failure (post-crash recovery) (`e9967b5`)
- fix(plugin): log re-listen failures once per streak, not every retry (`7ef2619`)
- fix(plugin): frame-skip TCPServer poll to mitigate Godot 4.4.1 FS-dock race (`5116694`)
- fix(plugin): nonce-based untrusted envelope to prevent tag-breakout injection (`0e730a1`)
- fix(plugin): resource.write error messages include hint keywords for guard tests (`a8adff5`)
- fix(plugin): replace stale resource.create references with resource.write (`72c8684`)
- fix(plugin): keep responsive WebSocket polling when editor is unfocused (`0d0c9a5`)
- fix(plugin): track missing classdb_commands.gd.uid (`801767b`)
- fix(plugin): race condition crash on shutdown, exception handling audit, runtime port 9090 → 6525 (`fc30d13`)

## Refactors

- refactor(plugin): mcp_error helper + structured returns replace push_error/assert (`6603193`)
- refactor(plugin): extract command registry with tier membership and per-domain command modules (`e41ab42`)
- refactor(plugin): remove class_name from all internal scripts, use centralized _hub.gd preloads (`0532ffc`)
- refactor(plugin): rename input parameter keys for LLM discoverability (`48cbf6c`)
- refactor(plugin): remove dead tier field, iteration refs, redundant comments; generalize to MCP client (`b7cbd39`)

## Documentation

- docs: flip dogfood guidance — toolkit-root canonical post-iter-13c F3 mitigation (`a6f7e7f`)

## Chores

- chore(plan): scaffold toolkit repo (root Godot project + addons/godot_mcp_toolkit + dogfood .mcp.json) (`9bd95d5`)
- chore(config): gitignore .vscode/ and .idea/ (user-machine paths) (`b01971d`)
- chore(config): ignore .claude/ — per-machine dogfood state, not portable (`cab5de5`)
- chore(config): rename npm server refs to @npgamedev/godot-mcp-server + path-based dogfood .mcp.json (`72ce199`)
- chore(gitignore): cover persistent smoke-probe artifacts (`93994f6`)
- chore(config): bump version to 1.0.0 + add version extraction script (`681731c`)
- chore(config): add .editorconfig for GDScript conventions (`35c2735`)

## Other

- Initial commit (`15dcfbd`)

