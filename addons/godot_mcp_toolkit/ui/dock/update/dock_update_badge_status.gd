@tool
extends RefCounted
## The dock update badge's status line: the text under the badge's title for what the
## update installer reports.
##
## Each function takes plain values the badge reads from the installer and returns the
## line, with its lines joined by newlines, or an empty string when the badge shows no
## status line. Which line a state picks lives here; the badge only renders it.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const UpdateApplier = Modules.UpdateApplier
const UpdateInstaller = Modules.UpdateInstaller
const RestartGate = UpdateInstaller.RestartGate
const EditorRestartProbe = UpdateInstaller.EditorRestartProbe
const VersionUtils = Modules.VersionUtils

## The [param facts] key for the number of toolkit files the project changed, an int.
const CHANGED := "changed"
## The [param facts] key for why the last download or stage failed, a String.
const ERROR := "error"
## The [param facts] key for why the version cannot be installed from the editor, a String.
const NOTE := "note"
## The [param facts] key for the open ready view, a Dictionary, empty while it is closed.
const VIEW := "view"
## The [param facts] key for why the editor's last exit left the staged update uninstalled,
## a String.
const POSTPONED := "postponed"

const _DOWNLOADING_TEXT := "Downloading %s…"
const _PREPARING_TEXT := "Preparing %s…"
const _READY_TEXT := "%s installs when you close the editor. Restart now to install it at once."
const _READY_RETRY_TEXT := "%s tries to install again when you close the editor. Restart now to install it at once."
const _POSTPONED_TEXT := "When the editor last closed, the update didn't install: %s."
const _FAILED_TEXT := "Couldn't install: %s."
const _CHANGED_TEXT := ("%d toolkit files were changed in this project; installing replaces them. "
		+ "The toolkit keeps a copy of the current version until the next update is staged. "
		+ "If Keep Backup is off in Project Settings, it deletes the copy once this update installs.")
const _READY_VIEW_TEXT := "%s is ready. It installs when you close the editor."
const _READY_VIEW_RETRY_TEXT := "%s is ready. It tries to install again when you close the editor."
const _READY_VIEW_HOW_TEXT := "To install it now, save your work and click Restart."
const _RUNNING_GAME_TEXT := "Restart stops the running game."
const _UNSAVED_SCRIPT_TEXT := "%s has unsaved edits. Save it, then click Restart."
const _UNSAVED_SCRIPTS_TEXT := "%d scripts have unsaved edits: %s. Save them, then click Restart."
# For an editor whose script tabs could not be paired with their files.
const _UNNAMED_SCRIPT := "A script"
const _UNNAMED_SCRIPTS_TEXT := "%d scripts have unsaved edits. Save them, then click Restart."
const _UNTITLED_SCENE_TEXT := "1 open scene has never been saved."
const _UNTITLED_SCENES_TEXT := "%d open scenes have never been saved."
const _SCRIPTS_ONLY_TEXT := "The toolkit only checks scripts. Save scenes, shaders and other open work yourself."
const _SCENES_NOT_ASKED_TEXT := ("Godot 4.2 and 4.3 don't ask about unsaved scenes when they restart, "
		+ "so unsaved scene changes are lost. Save before you click Restart.")
const _SERVER_CHANGED_TEXT := "It's tested with server %s, which .mcp.json doesn't run yet. Update .mcp.json, then restart your MCP client."
const _NOT_INSTALLED_TEXT := "%s. Version %s is still installed. Install log: %s"
const _NEXT_RELEASE_TEXT := "The toolkit offers the next release once it is published and checked."


## The status line for [param version] in the installer's [param state], one of the
## [code]UpdateInstaller[/code] state names. [param facts] holds what the state's line
## needs, under [constant CHANGED], [constant ERROR], [constant NOTE], [constant VIEW] and
## [constant POSTPONED]; a missing key reads as empty. Returns an empty string when the
## state has nothing to say.
static func install_line(state: String, version: String, facts: Dictionary) -> String:
	match state:
		UpdateInstaller.AVAILABLE:
			var changed: int = int(facts.get(CHANGED, 0))
			return _CHANGED_TEXT % changed if changed > 0 else ""
		UpdateInstaller.DOWNLOADING:
			return _DOWNLOADING_TEXT % version
		UpdateInstaller.PREPARING:
			return _PREPARING_TEXT % version
		UpdateInstaller.READY:
			return _ready_line(version, facts)
		UpdateInstaller.FAILED:
			return _FAILED_TEXT % str(facts.get(ERROR, ""))
	return str(facts.get(NOTE, ""))


## The ready view's status lines for the staged [param version], from the installer's
## [param view]: the probe's findings, each told on its own line, and whether this
## editor's restart asks about unsaved scenes. [param retry] is set when the editor's last
## exit already tried to install it, so the first line says the next exit tries again.
static func ready_view_text(version: String, view: Dictionary, retry: bool = false) -> String:
	var first := _READY_VIEW_RETRY_TEXT if retry else _READY_VIEW_TEXT
	var lines := PackedStringArray([first % version, _READY_VIEW_HOW_TEXT])
	if bool(view.get(EditorRestartProbe.RUNNING_GAME, false)):
		lines.append(_RUNNING_GAME_TEXT)
	var unsaved: PackedStringArray = view.get(EditorRestartProbe.UNSAVED_SCRIPTS, PackedStringArray())
	if not unsaved.is_empty():
		lines.append(_unsaved_scripts_line(unsaved))
	var untitled: int = int(view.get(EditorRestartProbe.UNTITLED_SCENES, 0))
	if untitled == 1:
		lines.append(_UNTITLED_SCENE_TEXT)
	elif untitled > 1:
		lines.append(_UNTITLED_SCENES_TEXT % untitled)
	var scenes_asked: bool = bool(view.get(RestartGate.SCENES_ASKED, false))
	lines.append(_SCRIPTS_ONLY_TEXT if scenes_asked else _SCENES_NOT_ASKED_TEXT)
	return "\n".join(lines)


## The status line under the last install's result, from the installer's
## [param notice]. A failed install names its reason, the version kept and the install
## log at [param log_path]; an installed one says nothing unless [param server_line]
## is set, when .mcp.json runs another server than the one the new version is tested with.
static func notice_line(notice: Dictionary, log_path: String, server_line: bool) -> String:
	if str(notice.get("kind", "")) == UpdateInstaller.NOTICE_UPDATED:
		return _SERVER_CHANGED_TEXT % VersionUtils.COMPATIBLE_SERVER_VERSION if server_line else ""
	var reason := str(notice.get("reason", ""))
	var line := _NOT_INSTALLED_TEXT % [_sentence(reason), str(notice.get("from_version", "")), log_path]
	# A hand download checks no signature, and in a leak the latest release can be the
	# old key's too, so this notice points at the toolkit's own check and offers no link.
	if reason == UpdateApplier.UNTRUSTED_SIGNATURE:
		line += "\n" + _NEXT_RELEASE_TEXT
	return line


# The staged update's line, or the ready view while it is open, then why the last exit
# left it uninstalled when it did.
static func _ready_line(version: String, facts: Dictionary) -> String:
	var view: Dictionary = facts.get(VIEW, {})
	var postponed := str(facts.get(POSTPONED, ""))
	var retry := not postponed.is_empty()
	var line := ""
	if not view.is_empty():
		line = ready_view_text(version, view, retry)
	else:
		line = (_READY_RETRY_TEXT if retry else _READY_TEXT) % version
	if retry:
		line += "\n" + _POSTPONED_TEXT % postponed
	return line


# Names the scripts when the editor paired every tab with its file, and counts them
# otherwise.
static func _unsaved_scripts_line(unsaved: PackedStringArray) -> String:
	var named := PackedStringArray()
	for file_name: String in unsaved:
		if not file_name.is_empty():
			named.append(file_name)
	if named.size() < unsaved.size():
		if unsaved.size() == 1:
			return _UNSAVED_SCRIPT_TEXT % _UNNAMED_SCRIPT
		return _UNNAMED_SCRIPTS_TEXT % unsaved.size()
	if named.size() == 1:
		return _UNSAVED_SCRIPT_TEXT % named[0]
	return _UNSAVED_SCRIPTS_TEXT % [named.size(), ", ".join(named)]


# A reason from the installer or the applier starts lowercase; the badge shows it as
# a sentence.
static func _sentence(reason: String) -> String:
	if reason.is_empty():
		return "The update did not install"
	return reason.left(1).to_upper() + reason.substr(1)
