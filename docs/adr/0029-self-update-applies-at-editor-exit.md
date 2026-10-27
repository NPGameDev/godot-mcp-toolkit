# 0029 — The toolkit installs its own updates at editor exit, from a signed manifest

**Status:** Proposed

**Date:** 2026-10-26

**Relates to:** [ADR 0026](0026-pin-server-version-in-mcp-json.md) (the server pin a toolkit
update moves) and [ADR 0027](0027-setup-steps-by-id-in-a-versioned-file.md) (the setup step
that asks for consent).

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
  4.2 did not reload at all.
- **Writing, then disabling and enabling the plugin.** Only `plugin.gd` loaded anew; the scripts
  it preloads came from the cache, and `compose()` failed with the wrong argument count (4.2 and
  4.7.2). No server came up.
- **Writing, then `restart_editor`.** Clean while no dialog intervenes. From 4.5 an unsaved
  script opens "Save changes to the following script(s)?", the editor stays up on the new files,
  and the next focus-in reloads them as above.
- **Writing in the plugin's `_exit_tree` while the editor exits.** Clean on all six versions:
  cancelling the dialog changed nothing, and OK, a restart or a normal quit installed 1.1.0,
  which started with its server listening and no toolkit error.

Calling `restart_editor` from the plugin's own code crashed 4 of 5 runs on 4.3+, because
`_exit_editor` frees the editor's plugins synchronously (`unload_editor_addons()`, absent in
4.2) while the calling function is still on the stack.

## Decision

**The toolkit verifies and stages an update while the editor runs, and writes it only from the
plugin's `_exit_tree` when the editor exits for any reason other than a disable.**

- **Staging.** The installer (`update/update_installer.gd`) follows the update check's newer
  version. It downloads the release's update manifest and its signature, verifies the signature
  against `update/trusted_release_keys.gd`, then the zip the manifest pins by size and SHA-256,
  and checks the zip's layout. Everything stays in `user://addons/godot_mcp_toolkit/update/`
  with a record of the state. Every URL is built from the version, never taken from a reply.
- **Applying.** `plugin.gd`'s `_exit_tree` calls `UpdateApplier.apply_pending()` after the graph
  is disposed. It re-checks the staged files, copies the installed folder to a backup, writes
  every release file and reads it back (the editor's safe save reports a failed rename only by
  printing), deletes the files the installed release listed and the new one dropped, and on any
  failure writes the backup back. An editor ended by a signal skips `_exit_tree`; the update
  waits for the next normal exit.
- **Restart now** is a convenience: it saves the scenes, then defers
  `restart_editor(false)`, so the restart runs outside the plugin's call stack. A dialog the user
  cancels leaves nothing written.
- **Signatures.** A release is installable only when its manifest carries an RSA-SHA256
  signature by a trusted key (`openssl dgst -sha256 -sign`, checked with `Crypto.verify`), which
  `scripts/sign-release.sh` makes over the manifest CI built. Where the private key is kept is
  open (below). With no trusted key the toolkit offers links only, as before.
  Rotation is a release that trusts both keys.
- **Consent and modes.** The project setting `mcp_toolkit/updates/install_mode` is `manual`,
  `ask` (default) or `automatic`, and lives in `project.godot` for the reason ADR 0026 gave the
  server pin: the files an update changes are committed, so the version is the team's choice.
  Until the setup step `update_install` is seen, every mode acts as `manual`.
- **What is never installed from the editor:** a major release, a release whose manifest needs a
  newer Godot than the running one, and any install in the toolkit's own repository, in a linked
  folder or a git checkout, or in a headless editor.
- **Release artifacts.** The zip carries `release_files.sha256`, the list of its files. The
  self-update deletes only files an installed release listed, so a user's own file in the folder
  survives, and it notices files changed by hand, which turn the automatic mode into a question.

## Considered and rejected

- **Hot-swapping the files mid-session, or disabling and enabling the plugin.** Measured above:
  new code on old state, or new entry point on old dependencies, and crashes on 4.3+.
- **Writing the files, then restarting.** Measured above: a save dialog can hold the restart and
  leave the editor running on the new files.
- **Applying at the next start, before the plugin loads.** `plugin.gd` preloads the rest of the
  toolkit at parse time, so the old files are loaded before any code could swap them; it would
  need a loader plugin with no preloads, and the exit hook already avoids the problem.
- **A checksum without a signature.** A hash published in the same release only proves the
  download matches the release; whoever can change the release can change both.
## Open: where the signing key is kept

The maintainer decides, and until a key is chosen the trusted key list stays empty. Two places
fit the tooling as built:

- **Off GitHub, signed by hand.** After the release workflow attaches the manifest, its holder
  signs it with `scripts/sign-release.sh` and uploads the signature: one manual step per release,
  and a compromised repository or workflow dependency cannot sign.
- **A GitHub environment secret with a required reviewer.** The workflow signs with no manual
  step, but whoever takes the repository or a workflow dependency can sign with it, which is the
  attack the signature exists to stop.

## Consequences

- **A release that installs but does not load cannot be undone from inside,** since the updater
  is part of what failed. The six-minor release gate, the manifest's Godot floor and the backup,
  with its troubleshooting entry, are the mitigation.
- **The first release that ships the installer updates itself from then on;** older installs
  update by hand once.
- **A stolen key reaches projects in the automatic mode.** Where the key is kept, rotation and
  the `ask` default bound it.
- **Installs from the legacy Asset Library** (an archive of the tagged commit) carry no file
  list, so their update deletes nothing; files a release dropped stay behind, unused.
- **Several teammates in the automatic mode** each produce the same diff of the addon folder.
- **`scripts/test_framework/update_flow.sh`** runs the flow end to end on scratch projects in
  CI, on the floor's boundaries, and in the release workflow against the built zip;
  **`scripts/test_framework/update_gui.sh`** checks what a user clicks, in editors with a window on
  a virtual display, in the cross-version workflow.
