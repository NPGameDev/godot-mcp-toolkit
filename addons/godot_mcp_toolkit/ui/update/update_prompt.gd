@tool
extends RefCounted
## The editor-start window that asks whether to install a verified toolkit release.
##
## Shown once per editor start in the ask mode, when the update installer holds a
## verified release and the setup wizard is not open. Update installs it, Later asks
## again at the next start, and Skip this version hides it until a newer one. What's
## in this update opens the version's changelog and leaves the window open. A release
## found during a session gets the dock badge only: a window in the middle of someone's
## work would be in the way. When installing would move the toolkit's server pin in
## .mcp.json, the window says so; there is nothing to choose, as the notice after the
## install offers Undo.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const UpdateCheck = Modules.UpdateCheck
const UpdateInstaller = Modules.UpdateInstaller
const ServerPinMove := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_move.gd")

## The label of the button that opens the changelog.
const WHATS_NEW_LABEL := "What's in this update"

const _TITLE := "Godot MCP Toolkit update"
const _TEXT := ("Godot MCP Toolkit %s is available. Install it now?\n\n"
		+ "Update downloads it from the toolkit's GitHub releases. The update installs when the "
		+ "editor restarts or closes, and Godot 4.4 and later restart on their own when no script "
		+ "has unsaved edits, no game is running and no open scene is untitled. Save your work "
		+ "first: restarting from the dock stops a running game and can't "
		+ "ask about every unsaved file.\n\n"
		+ "The new files show up in version control; commit them so everyone on the project "
		+ "runs the same version.")
const _DELETES_OTHER_FILES_TEXT := ("\n\nInstalling replaces the whole addon folder and "
		+ "deletes any other files you added to it.")
const _KEPT_COPY_TEXT := ("\n\nThe toolkit keeps a copy of the current version until the next "
		+ "update is staged. If Keep Backup is off in Project Settings, it deletes the copy "
		+ "once this update installs.\n\n")
# The file list goes last: at up to nine lines, it would split the sentences around it.
const _CHANGED_FILE_TEXT := "1 toolkit file was changed in this project, and installing replaces it:\n%s"
const _CHANGED_FILES_TEXT := "%d toolkit files were changed in this project, and installing replaces them:\n%s"
const _SKIP_ACTION := "skip"
const _WHATS_NEW_ACTION := "whats_new"
# How many changed files the window names before it stops listing.
const _LISTED_CHANGES := 8

var _installer: UpdateInstaller = null
var _dialog: ConfirmationDialog = null


## Shows the window for [param installer]'s release over the editor. Does nothing
## while a window from this prompt is open.
func show_for(installer: UpdateInstaller, pin_move: ServerPinMove = null) -> void:
	if _is_open():
		return
	_installer = installer
	open_under(EditorInterface.get_base_control(), offer_text(installer, pin_move))


## Builds the window with [param text] under [param parent] and pops it up centred.
## Does nothing while a window from this prompt is open. Returns the new window, which
## this prompt frees when it closes or tears down, or null when one was already open.
func open_under(parent: Node, text: String) -> ConfirmationDialog:
	if _is_open():
		return null
	var dialog := ConfirmationDialog.new()
	dialog.title = _TITLE
	dialog.dialog_text = text
	dialog.dialog_autowrap = true
	# Godot 4.4+ parents editor dialogs under an exclusive window; freeing it frees them.
	dialog.exclusive = false
	dialog.min_size = Vector2i(520, 0)
	dialog.ok_button_text = "Update"
	dialog.cancel_button_text = "Later"
	dialog.add_button(WHATS_NEW_LABEL, false, _WHATS_NEW_ACTION)
	dialog.add_button("Skip this version", true, _SKIP_ACTION)
	dialog.confirmed.connect(_on_confirmed)
	dialog.canceled.connect(_close)
	dialog.custom_action.connect(_on_custom_action)
	_dialog = dialog
	parent.add_child(dialog)
	dialog.popup_centered()
	return dialog


## Frees the window at once, for plugin teardown: a deferred free would hold it past
## the editor's exit-time leak check.
func teardown() -> void:
	if _is_open():
		_dialog.free()
	_dialog = null
	_installer = null


## The window's text for the release [param installer] offers. [param pin_move] is this
## start's pin move, which adds a line when installing would move the .mcp.json pin, or
## [code]null[/code] for no line.
static func offer_text(installer: UpdateInstaller, pin_move: ServerPinMove = null) -> String:
	var pin_preview: Dictionary = pin_move.preview(installer.offered_compatible_server()) if pin_move != null else {}
	return text_for(installer.version(), installer.changed_files(),
			not installer.discarded_files().is_empty(), pin_preview)


## The window's text for [param version] when [param changed_files] were changed by
## hand, warning that installing deletes other files when [param deletes_other_files].
## [param pin_preview] is what [code]ServerPinMove.preview[/code] returned; a non-empty
## one adds the line about the .mcp.json pin.
static func text_for(
		version: String, changed_files: PackedStringArray, deletes_other_files: bool = false,
		pin_preview: Dictionary = {}) -> String:
	var text := _TEXT % version
	if deletes_other_files:
		text += _DELETES_OTHER_FILES_TEXT
	if not pin_preview.is_empty():
		text += "\n\n" + ServerPinMove.preview_line(pin_preview)
	if changed_files.is_empty():
		return text
	var listed := PackedStringArray()
	for index in mini(changed_files.size(), _LISTED_CHANGES):
		listed.append("  " + changed_files[index])
	if changed_files.size() > _LISTED_CHANGES:
		listed.append("  …")
	var names := "\n".join(listed)
	if changed_files.size() == 1:
		return text + _KEPT_COPY_TEXT + _CHANGED_FILE_TEXT % names
	return text + _KEPT_COPY_TEXT + _CHANGED_FILES_TEXT % [changed_files.size(), names]


## The changelog What's in this update opens for [param version], built locally from
## the version, or an empty string for a version that names no release.
static func whats_new_url(version: String) -> String:
	return UpdateCheck.changelog_url(version)


func _is_open() -> bool:
	return _dialog != null and is_instance_valid(_dialog)


func _on_confirmed() -> void:
	if _installer != null:
		_installer.install()
	_close()


func _on_custom_action(action: StringName) -> void:
	if str(action) == _WHATS_NEW_ACTION:
		# Reading the notes is no answer, so the window stays up for one.
		if _installer != null:
			var url := whats_new_url(_installer.version())
			if url.begins_with("https://"):
				OS.shell_open(url)
		return
	if str(action) == _SKIP_ACTION and _installer != null:
		_installer.discard()
	_close()


# Runs inside the dialog's own signal, where an immediate free would delete the
# emitter mid-emission.
func _close() -> void:
	if _is_open():
		_dialog.queue_free()
	_dialog = null
