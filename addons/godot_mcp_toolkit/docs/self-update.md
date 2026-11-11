# Self-update

The toolkit can install its own updates. This page says what it downloads, what it
writes and where, and what it asks you first. The setup step that asks whether the
toolkit may install updates points here.

## What it downloads, and when

At most once a day the update check asks GitHub whether a newer version is out, and
when one is, asks the Asset Store whether it lists that version yet. That check is
its own setting, `mcp_toolkit/updates/check_for_updates`, and its own setup step.

When the toolkit may install updates (see [Consent](#consent)) and the check finds a
newer version it could install, the toolkit downloads only what it needs to check
that release, before you click anything:

1. Any trust document this machine doesn't have yet. It asks for the next one by
   number until GitHub has none, so this is one request when nothing changed.
2. The release's update manifest, `godot-mcp-toolkit-<version>.update.json`.
3. The manifest's signature, `godot-mcp-toolkit-<version>.update.json.sig`.

If the signature checks out, the dock's badge offers the update, and the editor can
ask at its next start. The manifest and signature are kept, so a later editor start
offers the same release without downloading them again. When you're up to date,
nothing is downloaded beyond the update check. Nothing is checked while an update
waits to install.

The release zip, `godot-mcp-toolkit-<version>.zip`, downloads only after you click
**Update**. That click first asks again for a newer trust document.

Every file comes from the toolkit's GitHub releases. The URLs are built from the
version number or the trust document's number, never taken from a reply. A
download may follow a redirect only to `github.com` or to a host under
`githubusercontent.com` other than `raw.githubusercontent.com`, where anyone can
publish a file.

## What it writes, and where

**The update folder, `res://addons/.godot_mcp_toolkit_update/`.** Everything the
update works with lives here, beside the addon:

- `.gitignore`, `.p4ignore` and `.gdignore`, which keep the folder out of version
  control and out of Godot's file system (see [Version control](#version-control))
- a folder named for the version, holding the manifest and the signature, and the
  zip once you click **Update**
- `journal.json`, which records how far an update has got, from the download on
- `stage/`, the new version unpacked from the zip
- `backup-<version>/`, the version an update replaced
- `install.log`, a line for each step and each failure

Godot's file system dock, the exporter and the Plugins list skip a folder whose name
starts with a dot. The toolkit's export strip also leaves the folder out of exports,
and the toolkit's MCP tools refuse to read or write it.

**The addon folder, `res://addons/godot_mcp_toolkit/`.** The toolkit writes it only
when the editor closes or restarts. It then checks the ready update again (the
signature, the manifest, the zip's hash and the list of files in the zip), moves the
current addon folder to `backup-<version>/` and moves `stage/` into its place. If the
second move fails, the backup goes back where it was and the update waits for the
next close. The recovery plugin may also move a version into place at the next start
(see [If an update doesn't load](#if-an-update-doesnt-load)).

After a successful update, the next start deletes the download and the stage. The
backup stays until the next update is ready. Turn off **Keep Backup**
(`mcp_toolkit/updates/keep_backup`) and a successful update deletes the whole update
folder instead.

**The recovery plugin, `res://addons/.godot_mcp_toolkit_recovery/`.** While an update
is ready or installing, the toolkit keeps a second, small editor plugin here and adds
its `plugin.cfg` to the enabled plugins in `project.godot`. It loads nothing from the
addon folder, so it can still run at the next start when the new version doesn't (see
[If an update doesn't load](#if-an-update-doesnt-load)). Like the update folder, it is
hidden from the editor, kept out of exports, refused by the MCP tools, and carries its
own `.gitignore` and `.p4ignore`. The start that reports the update's result deletes
the folder and the entry, and so does turning the toolkit off. An update dropped
before it installs, for example when you discard it or switch to `manual`, leaves
them in place until the next start, which deletes them. If `project.godot`
can't be saved, the update doesn't install, and the dock says why.

**The trust documents.** These are a few KB each, named `trust-<number>.json`, and
are kept once per machine, so every project on it sees the same keys:

| OS | Folder |
| --- | --- |
| Windows | `%APPDATA%\godot_mcp_toolkit\trust\` |
| macOS | `~/Library/Application Support/godot_mcp_toolkit/trust/` |
| Linux | `$XDG_DATA_HOME/godot_mcp_toolkit/trust/`, or `~/.local/share/godot_mcp_toolkit/trust/` |

Without `APPDATA` on Windows, or `HOME` on macOS and Linux, the toolkit has nowhere
to keep them and installs nothing. The dock says which variable to set.

**`.mcp.json` and `project.godot`.** An update can move the server version in
`.mcp.json` (see [The server pin](#the-server-pin)). The setup step saves your
choice of install mode in `project.godot`.

## Consent

The setup step **Install updates** asks whether the toolkit may install its own
updates. Project Settings → Mcp Toolkit → Updates → **Install Mode**
(`mcp_toolkit/updates/install_mode`) keeps the answer:

- `ask` (the default): the dock's badge offers each new version and the editor can
  ask at its next start. Nothing downloads past the signature until you click
  **Update**.
- `manual`: the dock only links to new versions. Switching to `manual` also deletes
  an update that is waiting to install.

Any other value counts as `manual`.

The toolkit installs nothing until you have seen that setup step, and it needs the
update check on, with its own setup step seen. Until then every mode works as
`manual`. The mode is saved in `project.godot`, so it's the same for everyone who
works on the project.

There is no mode that installs without asking. An update changes files that
everyone on the project shares, so it has to stay visible.

**What never installs from the editor.** These get a link to the release instead:

- a new major version
- a version whose manifest needs a newer Godot than the one running
- any version, in the toolkit's own source repository
- any version, when the addon folder is a link to another place
- any version, when the addon folder is a git checkout or submodule; update it with
  git
- any version, in a headless editor

When it closes, the editor checks again the signature, that the version is newer, the
Godot it needs, and the last four rules above.

## Unsaved work

The toolkit saves nothing for you. Before a restart it checks three things: scripts
with unsaved edits, a game running from the editor, and open scenes that have never
been saved. It can't see unsaved edits to a scene that has a file, to a shader or to
anything another editor holds.

- **Restart** refuses while a script has unsaved edits, on every Godot version. The
  dock names the scripts to save. A running game or an untitled scene doesn't stop
  it: the dock tells you about them first.
- **Godot 4.4 and later** restart on their own when the update is ready, but only
  when no script has unsaved edits, no game is running and no open scene is
  untitled. Otherwise the dock waits for you to click **Restart**. When the editor
  restarts, Godot itself asks about unsaved scenes.
- **Godot 4.2 and 4.3** never restart on their own. Every update waits for you to
  click **Restart**. Their restart doesn't ask about unsaved scenes, so unsaved scene
  changes are lost. Save before you click.

You don't have to restart at all. The update also installs when you close the
editor normally. An editor that is killed or crashes installs nothing, and the
update waits for the next normal close.

## If an update doesn't load

At the next start, the recovery plugin checks whether the toolkit is running. If
the update left it off, a dialog says what the recovery plugin did and offers
**Restart now** and **Later**:

- **The new version did not load in your Godot.** The backup goes back into the
  addon folder, and the version that failed is deleted. The dock doesn't offer that
  version again until a newer one is out.
- **The editor was killed partway through the install.** The update is finished if
  its files are still whole, or the previous version goes back if they aren't.
- **Godot 4.2 needs one more restart.** An update that moves a script with a
  `class_name` can keep the new version from starting once on 4.2. Nothing is
  moved; the restart loads it.

Until you restart, the toolkit stays off. When the recovery plugin can't set things
right, or a new version loads but misbehaves, follow "The toolkit is off after an
update" in the troubleshooting guide:
<https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md#the-toolkit-is-off-after-an-update>

## The server pin

When an update you started installs, the toolkit moves its own server version in
`.mcp.json` to the one the new version was tested with. It does this only for a pin
the toolkit wrote: not when the project sets `mcp_toolkit/server/version`, which is
the lasting way to hold a version back, not when a local server path is set, and not
for a version you set by hand. The update notice names both versions and has an
**Undo**. The dock also warns when the connected server is older than the one this
toolkit recommends.

The full rules are in
[advanced_configuration.md, "After a self-update"](advanced_configuration.md#after-a-self-update).

## Version control

The update folder's own ignore files hide everything in it from Git and Diversion,
and from Perforce once it is set up to read them. Other systems need a rule of their
own.

- **Git** reads `.gitignore`, and so does **Diversion**.
- **Perforce** reads `.p4ignore` only when `P4IGNORE` names that file. This file has
  not been tested with Perforce.
- **Mercurial** reads only the `.hgignore` at the repository root. Add this line to
  it: `^addons/\.godot_mcp_toolkit_update/`. If that file uses `syntax: glob`, add
  `addons/.godot_mcp_toolkit_update/` instead.
- **Subversion** has no ignore file. Set the ignore property on `addons/`, then
  commit the property change:
  `svn propset svn:ignore .godot_mcp_toolkit_update addons`. If `addons/` already
  has an `svn:ignore` value, `propset` replaces it, so run
  `svn propedit svn:ignore addons` and add the line there instead.
- **Plastic SCM (Unity Version Control)** reads `ignore.conf` at the workspace
  root. Add `/addons/.godot_mcp_toolkit_update` to it. The rule hides only files
  that were never checked in, so add it before the folder is ever checked in.

With any other version control, ignore `addons/.godot_mcp_toolkit_update/` in your
project's own rules, or turn off **Keep Backup** so a successful update leaves
nothing behind. Ignore `addons/.godot_mcp_toolkit_recovery/` the same way: it comes
and goes with updates.

Because the folder is ignored, `git clean -fdX`, `git clean -fdx` and `git stash -a`
delete it, along with any update that is waiting and the backup.

The new addon files are not ignored. They show up as changes after an update:
commit them, so everyone on the project runs the same version.

## The addon folder belongs to the release

An update replaces `res://addons/godot_mcp_toolkit/` whole and copies nothing back.
Anything you keep in that folder is lost to any update, whether the toolkit installs
it or you do. Keep your own files, extensions included, in a folder of their own.

Before you click **Update**, the dock lists the toolkit files changed in this
project, which the update replaces.

## Limits

- **Godot 4.2 on Linux and macOS:** if the project's path holds `"`, `$`, a backtick
  or `\`, no update installs. The toolkit can't check safely whether the addon
  folder is a link, so it treats the folder as one.
- **Godot 4.2 on Windows:** the link check runs `fsutil`. If `fsutil` is missing or
  the system refuses to run it, no update installs, and the dock says the toolkit's
  folder is a link to another place. The folder may be an ordinary one: the toolkit
  refuses when it can't tell.
- **Cloud folders on Windows:** an addon folder that is a cloud-sync placeholder
  counts as a link, so no update installs. A placeholder whose files are online-only
  has not been tested.
- **Command-line runs:** a headless editor never installs. An `--import` or
  `--export-*` run without `--headless` is an editor that closes, so it installs a
  waiting update.

## Uninstalling

Delete `res://addons/.godot_mcp_toolkit_update/` along with the addon folder. Turning
the toolkit off first also deletes the recovery plugin's folder and its entry in
`project.godot`. The trust documents stay in the folder for your OS (see the table
above); they are safe to delete.

If an update went wrong, the troubleshooting guide has the steps:
<https://github.com/NPGameDev/godot-mcp-toolkit/blob/main/docs/troubleshooting.md#the-toolkit-is-off-after-an-update>
