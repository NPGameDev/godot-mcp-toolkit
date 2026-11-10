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

Set `GODOT_MCP_UPDATE_CHECK_HOST` in the editor's environment to a scheme and loopback host, for
example `http://127.0.0.1:8123`, before you start the editor; `localhost` and `[::1]` work too, and
any other value is ignored. It replaces the scheme and host of the check's request URLs and keeps
their paths, so the local server answers `/repos/NPGameDev/godot-mcp-toolkit/releases/latest` with
`{"tag_name": "vX.Y.Z"}` and `/api/v1/releases/npgamedev/godot-mcp-toolkit/` with a JSON array of
`{"version": "X.Y.Z", "stable": true}` entries. It redirects the self-update's downloads the same
way: the trust documents, the manifest, the signature and the zip
(`self_update/release_assets.gd`). The badge's links still point at GitHub and the Asset Store.

## Installing updates

ADR 0029 has the reasons, `docs/dev/trust-chain.md` the keys, and the glossary the terms; this is
the map of `self_update/`.

- `self_update/update_installer.gd` is a node the composer adds beside the update check runner. It
  follows the runner's newer, undismissed version, and offers it only when every gate holds:
  `Consent.may_install_updates` (the check's consent, the `update_install` setup step seen, and
  `mcp_toolkit/updates/install_mode` at `ask`), a trust document embedded in this release
  (`self_update/embedded_trust_document.gd`), a release in the same major, and no refusal from
  `self_update/install_guards.gd` (the toolkit's own repository, a linked addon folder, a git
  checkout of it, a headless editor).
- The check: `self_update/release_verifier.gd` walks the trust chain first, fetching the trust
  documents this machine lacks into `<data folder>/godot_mcp_toolkit/trust/`
  (`self_update/trust_chain.gd`), then fetches `godot-mcp-toolkit-<v>.update.json` and its `.sig`
  and checks them (`self_update/release_signature.gd`, `self_update/release_manifest.gd`). A release
  that needs a newer Godot stops there. The verified manifest and signature are kept in the update
  folder (`self_update/kept_release.gd`), so a later start offers the release without a request. A
  failed check says why in the badge (`self_update/update_check_failure.gd`).
- The download, after a click on Update: the installer walks the chain again, writes the update
  journal at `verified`, and fetches the zip through `self_update/update_downloader.gd`, which
  follows each redirect by hand and only to `github.com` or a `githubusercontent.com` host other
  than `raw.githubusercontent.com`. The zip must match the manifest's hash. Staging then unpacks it a
  few files a frame (`self_update/stage_runner.gd`, `self_update/stage_stepper.gd`), each entry
  checked against the release file list inside the zip, after `self_update/release_archive.gd` has
  checked the zip's layout. The journal goes to `staged`, and `self_update/restart_gate.gd`
  restarts the editor or opens the ready view.
- Everything lives in `addons/.godot_mcp_toolkit_update/` (`self_update/update_folder.gd`):
  `journal.json` (`self_update/update_journal.gd`), `install.log`, a `<version>/` folder with the
  zip, the manifest and its signature, `stage/`, and `backup-<version>/`. The folder writes its own
  `.gitignore`, `.p4ignore` and `.gdignore`, so `git clean -fdX` deletes it, and no code assumes it
  survives. With the editor closed, delete the folder to start over.
- The swap: `self_update/update_applier.gd` runs from `plugin.gd`'s `_exit_tree`, through
  `self_update/update_lifecycle.gd`, on every exit that is not a disable. It checks again the
  guards, the signature against the chain this machine holds, the manifest, the Godot floor, the
  zip's hash, the version order and the zip's layout, and that the stage holds exactly what the
  zip's file list names. Then it writes `applying`, renames the addon folder to the backup and the
  stage to the addon folder, and renames the backup back if the second rename fails. Nothing is
  copied back. Something that may pass by itself, such as a held file, leaves the update staged for
  the next exit. The exit does not read the install mode again: the click was the consent.
- The settle: at the next start, `self_update/update_settler.gd` compares the journal with the
  installed version, finishes or clears what it finds, and `self_update/update_notice.gd` turns the
  result into the badge's notice. An update that installed moves the server pin
  (`ui/mcp_json/server_pin_move.gd`, `contract.md` C11).
- `ui/dock/update/dock_update_badge.gd` shows Update, the download, Restart now and Don't install,
  the ready view, the last install's result, and Undo after a pin move.
  `ui/update/update_prompt.gd` is the ask mode's editor-start window.
- For a manual test against a local server, serve
  `/NPGameDev/godot-mcp-toolkit/releases/download/v<v>/` with the zip, the manifest and its
  signature. A release installs only when a key in the chain signed its manifest, and this
  repository's `embedded_trust_document.gd` is empty, so the toolkit under test needs a scratch copy
  whose embedded document lists a test key: `scripts/trust-document.sh` builds and signs one, and
  `scripts/sign-release.sh` signs the manifest. `ut_embed_trust` in `scripts/lib/update_test_env.sh`
  shows the steps. Never commit a test key or a test document.
- A headless editor never installs, settles or applies; `GODOT_MCP_UPDATE_ALLOW_HEADLESS=1` lifts
  that for tests. The install guards also refuse in this repository, so test in a scratch project.

### Testing it

`test/units/` has a `<module>_tests.gd` for each `self_update/` module but the editor restart probe
and the embedded trust document. `scripts/test_framework/update_flow.sh` runs the
whole flow headless on scratch projects: it builds the release from this tree and installs it over
the same tree one version older, then checks a folder that cannot move, an untrusted signature, the
repository guard and a disable. It needs Python 3, openssl, GNU `timeout` and zip, runs under a
scratch `HOME`, takes a few minutes, and runs on Linux, macOS and Windows (the
[local testing guide](../testing-locally.md) has the per-OS notes):

```bash
bash scripts/test_framework/update_flow.sh /path/to/godot
UPDATE_FLOW_LEGS="full rollback" UPDATE_FLOW_KEEP=1 bash scripts/test_framework/update_flow.sh godot
```

`scripts/test_framework/check_release_builds.sh` checks that the bash and PowerShell release builds
write the same release, and `test/apply_kill_driver/run_legs.sh` kills real editors at each step of
the swap.

`scripts/test_framework/update_gui.sh` checks the interface in editors with a window on a virtual
display: the badge's buttons, the editor-start window, the ready view, an exit by the quit shortcut,
the pin move and a major release. Its plugin, `test/update_gui_driver/`, finds the controls by name
(`UpdateBadge`, `UpdateButton`, `RestartButton`, `NotNowButton`, `UpdateMcpJsonButton`,
`UndoPinMoveButton`, `GitHubButton`, `Title`, `Status`, and the dock's `CompatLabel`), so renaming
one breaks it. The two scripts share `scripts/lib/update_test_env.sh`.
