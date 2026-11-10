# 0029 — The toolkit installs its own updates at editor exit, from a signed manifest

**Status:** Accepted

**Date:** 2026-11-10

**Relates to:** [ADR 0026](0026-pin-server-version-in-mcp-json.md) (the server pin a toolkit
update moves) and [ADR 0027](0027-setup-steps-by-id-in-a-versioned-file.md) (the setup step
that asks for consent). The keys and their rotation are in
[`docs/dev/trust-chain.md`](../dev/trust-chain.md).

## Context

Toolkit releases are frequent and carry fixes users want. The update check (1.1) tells users
about a release, but installing it is a manual download and unzip, and an addon cannot be
replaced like an ordinary file: its scripts are loaded and running in the editor that would
replace them. How the files are swapped decides whether the editor survives the swap.

Measured on 2026-10-26 with toolkit 1.0.4 replaced by 1.1.0 inside a running editor, on Godot
4.2, 4.3, 4.4, 4.5, 4.6 and 4.7.2 (Linux, a test-only plugin doing the swap):

- **Writing the files while the editor runs.** The editor rescans on focus-in
  (`EditorFileSystem::scan_changes()` on `NOTIFICATION_APPLICATION_FOCUS_IN`) and, on 4.3 and
  later, hot-reloads the changed scripts with their state kept: members survive by name, new
  members are empty, and `_init`, `_enter_tree` and `_enable_plugin` do not run again. 1.1.0's
  code then ran on the graph 1.0.4's `compose()` built, logging a dock error on every refresh,
  and disabling the plugin afterwards crashed the editor (signal 11) on every version from 4.3.
  Godot 4.2 (the patch was not recorded) did not reload at all.
- **Writing, then disabling and enabling the plugin.** Only `plugin.gd` loaded anew; the scripts
  it preloads came from the cache, and `compose()` failed with the wrong argument count (4.2 and
  4.7.2). No server came up.
- **Writing, then `restart_editor`.** Clean as long as no dialog comes up. From 4.4 the restart asks
  about unsaved work: an unsaved script opens "Save changes to the following script(s)?", the
  editor stays up on the new files, and the next focus-in reloads them as above. 4.2 and 4.3
  restart without asking.
- **Writing in the plugin's `_exit_tree` while the editor exits.** Clean on all six versions:
  cancelling the dialog changed nothing, and OK, a restart or a normal quit installed 1.1.0,
  which started with its server listening and no toolkit error.

Calling `restart_editor` from the plugin's own code crashed 4 of 5 runs on 4.3+, because
`_exit_editor` frees the editor's plugins synchronously (`unload_editor_addons()`, absent in
4.2) while the calling function is still on the stack.

## Decision

**The toolkit verifies and stages an update while the editor runs, and swaps it in only from the
plugin's `_exit_tree` when the editor exits for any reason other than a disable.**

- **Apply at exit, with a restart.** Update downloads and stages the release; when staging ends,
  the toolkit restarts the editor so the exit installs it. The restart is a deferred
  `restart_editor(false)`, so it runs outside the plugin's call stack, and the toolkit saves
  nothing (`self_update/restart_gate.gd`). Restart refuses while a script has unsaved edits, on
  every version. On 4.4 and later the editor restarts by itself when staging ends only when no
  script is unsaved, no game is running and no scene was never saved; otherwise, and always on
  4.2 and 4.3, the dock's ready view waits for the user's Restart. A restart-free install is not
  in 1.2.0: on 4.2 and 4.3 a re-enable in the same session ran cached scripts, and the code that
  installs is the one part of the toolkit an update can never fix. A later release may revisit
  it.
- **Two renames under a journal, in the update folder.** Everything lives in
  `res://addons/.godot_mcp_toolkit_update/`, beside the addon: the journal, the install log, the
  downloaded zip, manifest and signature, the unpacked stage and the backup
  (`self_update/update_folder.gd`). The engine's scanner, the exporter and the Plugins list skip a
  folder whose name starts with a dot, and the folder writes its own `.gitignore`, `.p4ignore` and
  `.gdignore`. At exit the applier (`self_update/update_applier.gd`) re-derives what the stage must
  hold from what is signed (signature, manifest, the zip's hash, the file list inside the zip),
  writes `applying` to the journal, renames the installed folder to `backup-<from>/` and renames
  the stage into its place. A failed second rename renames the backup back. The next start reads
  the journal and reports the result (`self_update/update_settler.gd`). An editor ended by a
  signal skips `_exit_tree`, and the update waits for the next normal exit.
  One risk remains: a kill in the 0 to 7 ms between the two renames leaves no installed folder,
  with the old and new copies both whole in the update folder. Recovery from that is by hand
  ([troubleshooting](../troubleshooting.md)), and a `git clean -fdX` in that state deletes both
  copies, so the toolkit has to be reinstalled.
- **Two install modes, `manual` and `ask`.** `mcp_toolkit/updates/install_mode` is `ask` (the
  default: the dock offers a release whose manifest and signature have been verified, and the
  zip downloads only when the user clicks Update) or `manual` (links only); any other value
  reads as `manual` (`self_update/install_mode.gd`). There is no mode that installs without
  asking, because an update must stay visible to whoever works in the project. Nothing installs
  until the update check may run and the setup step `update_install` has been seen
  (`core/consent.gd`). Switching to `manual` deletes a staged release.
- **The mode lives in `project.godot`,** for the reason ADR 0026 gave the server pin: the files
  an update changes are committed, so which version a project runs is the team's choice.
- **What never installs from the editor:** a major release, a release whose manifest needs a
  newer Godot than the running one, and any install in the toolkit's own repository, into a
  folder that is a link, into a git checkout or submodule, or from a headless editor
  (`self_update/install_guards.gd`). Those stay links. The exit checks the guards, the signature
  and the version order again before it renames anything.
- **Signing is offline.** The maintainer signs each release's manifest by hand, against a
  draft release, with a key kept off GitHub; no workflow ever holds a trusted release key. Where the
  keys are kept is in [Custody](../dev/trust-chain.md#custody).
- **The trust chain.** A release embeds a trust document listing root keys and release keys;
  a release key signs manifests, and root keys sign the next document. The client walks each
  next document from GitHub, verifies it against the previous roots and keeps it per machine in
  `godot_mcp_toolkit/trust/` inside the OS's data folder, so a revocation holds across projects.
  Keys have no expiry, a manifest carries no key id (keys are told apart by their PEM), and a
  manifest's `expires_at` is read but never refuses. The rules, caps and limits are in
  [`docs/dev/trust-chain.md`](../dev/trust-chain.md).
- **The pin moves with the update.** After an update the user started has installed, the
  toolkit moves its own `.mcp.json` server pin to the new release's recommended version, with a
  notice and Undo, when the pin is one the toolkit owns: the version setting is empty, no local
  server path is set, and the entry names the old recommended version or this machine's last
  write (`ui/mcp_json/server_pin_move.gd`, C11 in the [contract](../dev/contract.md)). A pin set
  by hand stays. This reverses ADR 0026's "nothing is rewritten silently" for that one case.
- **The addon folder belongs to the release.** An update replaces the folder whole, with no
  copy-back: a file a user keeps in `res://addons/godot_mcp_toolkit/` is lost to any update,
  manual too. The previous version stays as the backup until the next update is staged, or goes
  after a successful update when `mcp_toolkit/updates/keep_backup` is off.
- **What the installed applier reads is a contract.** The applier in a shipped release installs
  every later one and can never be patched on a machine that stays on it. So these stay readable
  by every older toolkit, and breaking one needs a bridge release first:
  - the zip's layout: every file under `addons/godot_mcp_toolkit/`, with `plugin.cfg` naming
    the release's version (`self_update/release_archive.gd`);
  - the file list's grammar: `release_files.sha256` in the addon folder, one
    `<sha256>  <path>` line per file in `sha256sum` format, naming exactly the zip's other files
    (`self_update/release_file_list.gd`);
  - the manifest's schema, `format` 1 with `version`, `archive`, `archive_size`,
    `archive_sha256` and `min_godot` required and unknown keys ignored
    (`self_update/release_manifest.gd`), and the asset names `godot-mcp-toolkit-<v>.zip`,
    `godot-mcp-toolkit-<v>.update.json` and its `.sig` (`self_update/release_assets.gd`);
  - the entry cap of 5000 and the name rules: no absolute path, `\`, `:` or empty, `.` or `..`
    segment; no `.gdignore`, `.gitignore` or `.p4ignore` at the addon root; no `project.godot`
    at any depth; no name Windows would change or open as a device; no file twice; no two names
    that differ only in letter case.

## Considered and rejected

- **Hot-swapping the files mid-session, or disabling and enabling the plugin.** Measured above:
  new code on old state, or new entry point on old dependencies, and crashes on 4.3+.
- **Writing the files, then restarting.** Measured above: a save dialog can hold the restart and
  leave the editor running on the new files.
- **Writing the release file by file at exit, with a backup copy.** A lab on Godot 4.2.0, 4.3
  and 4.7 on Windows, macOS and Linux killed the editor at each step of both strategies. Its worst
  case for the file-by-file write left the installed folder mixed between the two versions after
  a window of 148 to 2057 ms over 380 files, with the only full copy of the old version lost. The
  two renames' worst case is the 0 to 7 ms window above, with both copies whole.
- **Installing without asking.** It was built as an `automatic` mode and removed: an update
  must stay visible to whoever works in the project.
- **Applying at the next start, before the plugin loads.** `plugin.gd` preloads the rest of the
  toolkit at parse time, so the old files are loaded before any code could swap them; it would
  need a loader plugin with no preloads, and applying at exit does not have the problem.
- **A checksum without a signature.** A hash published in the same release only proves the
  download matches the release; whoever can change the release can change both.
- **Signing in a workflow, with the key as an environment secret.** It saves the manual step,
  but whoever takes the repository or a workflow dependency can sign with it, which is the
  attack the signature exists to stop.

## Consequences

- **A release that installs but does not load cannot be undone from inside,** since the updater
  is part of what failed. The six-minor release gate, the manifest's Godot floor and the backup,
  with its troubleshooting entry, limit the damage.
- **The first release that ships the installer updates itself from then on;** older installs
  update by hand once.
- **A stolen release key, with access to the repository, reaches the clients that have not yet
  seen the trust document that drops it.** The `ask` mode means a user still has to click
  Update.
- **Teammates who each install the same update** produce the same change to the addon folder,
  since a release's files are the same bytes.
- **`scripts/test_framework/update_flow.sh`** runs the flow end to end on scratch projects in
  CI and in the release workflow against the built zip;
  **`scripts/test_framework/update_gui.sh`** checks what a user clicks, in editors with a window
  on a virtual display, in the cross-version workflow; **`test/apply_kill_driver/run_legs.sh`**
  kills real editors at each step of the swap.
