# Update check and self-update: contributor notes

The dock's update badge comes from a small check the toolkit runs on its own, and the toolkit can
install the release it finds. This note says how both work and how to point them at a local server
while you work on them. Users read about them in the README's privacy line; the settings are listed
in `contract.md` (C22), and the decision record is ADR 0029.

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

## Installing updates

ADR 0029 has the reasons; this is the map.

- `update/update_installer.gd` is a node the composer adds after the update check runner and frees
  before it. When the runner reports a newer version, `Consent.may_install_updates` holds for the install mode (the
  check's consent, the `update_install` setup step seen, and `mcp_toolkit/updates/install_mode` at
  `ask` or `automatic`), `update/trusted_release_keys.gd` holds a key, the release is not a major
  one and no guard refuses (`update/install_guards.gd`), it downloads
  `godot-mcp-toolkit-<v>.update.json` and its `.sig` and verifies them
  (`update/release_signature.gd`, `update/release_manifest.gd`). In the automatic mode, or after a
  click on Update, it downloads the zip, checks it against the manifest and its layout
  (`update/release_archive.gd`), and stages it.
- `update/pending_update.gd` keeps the record and the files in
  `user://addons/godot_mcp_toolkit/update/`: `pending_update.json`, one folder per version, the
  backup and `install.log`. The record's state goes `verified` → `staged` → `applied`,
  `rolled_back` or `not_applied`; the next start turns the last three into the badge's notice and
  deletes the record. Delete the folder to start over.
- `update/update_applier.gd` runs from `plugin.gd`'s `_exit_tree` on every exit that is not a
  disable. It re-checks the staged files, backs the installed folder up, writes each file and reads
  it back (`update/folder_files.gd`), deletes the files the installed release listed and the new one
  dropped (`update/install_plan.gd`, `update/release_file_list.gd`), and restores the backup on any
  failure.
- `ui/dock/update/dock_update_badge.gd` shows Update, the download, Restart now and Don't install,
  and the last install's result, with Update .mcp.json when the new version is tested with another
  server than the one the toolkit wrote into `.mcp.json`. A release that becomes installable during the session also gets one
  toast. `ui/update/update_prompt.gd` is the ask mode's editor-start window.
- `GODOT_MCP_UPDATE_CHECK_HOST` also moves the three downloads; serve
  `/NPGameDev/godot-mcp-toolkit/releases/download/v<v>/` with the zip, the manifest and its
  signature. A local server's release installs only when its manifest is signed by a trusted key,
  so for a manual test put a test key's PEM in a scratch copy of `trusted_release_keys.gd`
  (`scripts/sign-release.sh --key-entry <public.pem>` prints the entry). Never commit a test key.
- A headless editor never installs; `GODOT_MCP_UPDATE_ALLOW_HEADLESS=1` lifts that for tests.

### Testing it

`test/units/` has one file per `update/` module. `scripts/test_framework/update_flow.sh` runs the
whole flow on scratch projects: it builds the release from this tree, installs it over the same tree
one version older, and checks a rollback, an untrusted signature, the repository guard and a
disable. It needs python3, openssl and zip, runs under a scratch `HOME`, and takes a few minutes:

```bash
bash scripts/test_framework/update_flow.sh /path/to/godot
UPDATE_FLOW_LEGS="full rollback" UPDATE_FLOW_KEEP=1 bash scripts/test_framework/update_flow.sh godot
```

`scripts/test_framework/update_gui.sh` checks the interface in editors with a window on a virtual
display: the badge's buttons, the editor-start window, Restart now with an unsaved script, the
automatic mode closed with Ctrl+Q, the `.mcp.json` offer and a major release. Its plugin,
`test/update_gui_driver/`, finds the badge's controls by name (`UpdateBadge`, `UpdateButton`,
`RestartButton`, `DiscardButton`, `UpdateMcpJsonButton`, `GitHubButton`, `AssetStoreButton`,
`Title`, `Status`), so renaming one breaks it. Both scripts share `scripts/lib/update_test_env.sh`.
