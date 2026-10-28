@tool
extends RefCounted
## The editor-start window that asks whether to install a verified toolkit release.
##
## Shown once per editor start in the ask mode, when the update installer holds a
## verified release and the setup wizard is not open. Update installs it, Later asks
## again at the next start, and Skip this version hides it until a newer one. A
## release found during a session gets the dock badge only: a window in the middle
## of someone's work would be in the way.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const UpdateInstaller = Modules.UpdateInstaller

const _TITLE := "Godot MCP Toolkit update"
const _TEXT := ("Godot MCP Toolkit %s is available. Install it now?\n\n"
		+ "It downloads from the toolkit's GitHub releases and installs when you close or "
		+ "restart the editor. The new files show up in version control; commit them so "
		+ "everyone on the project runs the same version.")
const _CHANGED_TEXT := ("\n\n%d toolkit files were changed in this project, and installing "
		+ "replaces them. A copy is kept until the new version starts:\n%s")
const _SKIP_ACTION := "skip"
# How many changed files the window names before it stops listing.
const _LISTED_CHANGES := 8

var _installer: UpdateInstaller = null
var _dialog: ConfirmationDialog = null


## Shows the window for [param installer]'s release over the editor. Does nothing
## while a window from this prompt is open.
func show_for(installer: UpdateInstaller) -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	_installer = installer
	var dialog := ConfirmationDialog.new()
	dialog.title = _TITLE
	dialog.dialog_text = text_for(installer.version(), installer.changed_files())
	dialog.dialog_autowrap = true
	dialog.min_size = Vector2i(520, 0)
	dialog.ok_button_text = "Update"
	dialog.cancel_button_text = "Later"
	dialog.add_button("Skip this version", true, _SKIP_ACTION)
	dialog.confirmed.connect(_on_confirmed)
	dialog.canceled.connect(_close)
	dialog.custom_action.connect(_on_custom_action)
	_dialog = dialog
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()


## Frees the window at once, for plugin teardown: a deferred free would hold it past
## the editor's exit-time leak check.
func teardown() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.free()
	_dialog = null
	_installer = null


## The window's text for [param version] when [param changed_files] were changed by
## hand.
static func text_for(version: String, changed_files: PackedStringArray) -> String:
	var text := _TEXT % version
	if changed_files.is_empty():
		return text
	var listed := PackedStringArray()
	for index in mini(changed_files.size(), _LISTED_CHANGES):
		listed.append("  " + changed_files[index])
	if changed_files.size() > _LISTED_CHANGES:
		listed.append("  …")
	return text + _CHANGED_TEXT % [changed_files.size(), "\n".join(listed)]


func _on_confirmed() -> void:
	if _installer != null:
		_installer.install()
	_close()


func _on_custom_action(action: StringName) -> void:
	if str(action) == _SKIP_ACTION and _installer != null:
		_installer.discard()
	_close()


# Runs inside the dialog's own signal, where an immediate free would delete the
# emitter mid-emission.
func _close() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null
