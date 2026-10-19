# Update check: contributor notes

The dock's update badge comes from a small check the toolkit runs on its own. This note says how it
works and how to point it at a local server while you work on it. Users read about it in the
README's privacy line; the setting is listed in `contract.md` (C22).

## How it runs

- `versioning/update_check.gd` holds the pure rules: the strict version compare, the reply
  parsing, the once-a-day rule and the request builder. `test/units/update_check_tests.gd` covers
  them.
- `versioning/update_check_runner.gd` is a node the composer adds under the plugin. At enable and
  every hour it re-reads its state file. When 24 hours have passed since the project's last check,
  it writes the new check time first and then sends
  `GET https://api.github.com/repos/NPGameDev/godot-mcp-toolkit/releases/latest`. When that
  release's `tag_name` is a newer stable version, it sends one
  `GET https://store.godotengine.org/api/v1/releases/npgamedev/godot-mcp-toolkit/` to learn
  whether the store lists it. Both send only `User-Agent: godot-mcp-toolkit` beyond the engine's
  own `Host`, `Accept` and `Accept-Encoding` headers, with no query and no body, and time out after
  10 seconds. Every failure is silent and keeps the cached result.
- The state file is `user://addons/godot_mcp_toolkit/update_check_cache.json`, per project and per
  machine: `last_check` (unix seconds), `latest_version`, `store_listed` and `dismissed_version`.
  Delete it to make the next enable check at once.
- `ui/dock/update/dock_update_badge.gd` renders the result as the dock's first child. Its links are
  built from the version, never taken from a reply.
- `mcp_toolkit/updates/check_for_updates` set to `false` sends nothing and hides the badge.
- Nothing is sent until the consent gate (`core/consent.gd`) allows it: the toggle on and the
  setup wizard's `updates` step seen (ADR 0027). An editor that has never shown the wizard, such as
  a headless one, never checks. After the step is seen, the first check goes out on the next hourly
  tick or when the plugin next loads, at an editor start or an enable. To work on the check in a
  project, leave the wizard's Updates step with Next once.

## Pointing the check at a local server

Set `GODOT_MCP_UPDATE_CHECK_HOST` in the editor's environment to a scheme and host, for example
`http://127.0.0.1:8123`, before you start the editor. It replaces the scheme and host of both
request URLs and keeps their paths, so the local server answers
`/repos/NPGameDev/godot-mcp-toolkit/releases/latest` with `{"tag_name": "vX.Y.Z"}` and
`/api/v1/releases/npgamedev/godot-mcp-toolkit/` with a JSON array of
`{"version": "X.Y.Z", "stable": true}` entries. A value that does not start with `http://` or
`https://` is ignored. The badge's links still point at GitHub and the Asset Store, so a local
server can change only the version the badge shows.
