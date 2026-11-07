@tool
extends RefCounted
## What the restart decision asks of the running editor: the work a restart would lose,
## whether a file scan is running, and the restart itself.
##
## Outside a windowed editor, as in a unit test or a headless run, it finds nothing and
## never restarts. A test hands the installer a stand-in that extends this script.

# Direct preload, not core/modules.gd: the aggregator preloads the installer,
# which reaches this file.
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## [method findings] keys. The file names of the open scripts with unsaved edits, in tab
## order, an empty name where the editor's tabs cannot be paired with their scripts.
const UNSAVED_SCRIPTS := "unsaved_scripts"
## Whether a game started from the editor is running.
const RUNNING_GAME := "running_game"
## How many open scenes have never been saved to a file.
const UNTITLED_SCENES := "untitled_scenes"


## What a restart now would lose: [code]{UNSAVED_SCRIPTS: PackedStringArray,
## RUNNING_GAME: bool, UNTITLED_SCENES: int}[/code].
func findings() -> Dictionary:
	if not can_restart():
		return {UNSAVED_SCRIPTS: PackedStringArray(), RUNNING_GAME: false, UNTITLED_SCENES: 0}
	return {
		UNSAVED_SCRIPTS: _unsaved_scripts(),
		RUNNING_GAME: EditorInterface.is_playing_scene(),
		UNTITLED_SCENES: _untitled_scenes(),
	}


## The running engine's [code]major.minor[/code].
func engine_version() -> String:
	return VersionUtils.get_engine_version_pair()


## Whether this is an editor with a window, the only kind a restart makes sense in.
func can_restart() -> bool:
	return Engine.is_editor_hint() and not VersionUtils.is_headless()


## Whether the editor's file system scan is running.
func is_scanning() -> bool:
	return can_restart() and EditorInterface.get_resource_filesystem().is_scanning()


## Restarts the editor without saving. Deferred, so it runs outside the caller: the
## editor frees its plugins while it exits, and a plugin function still on the stack
## would crash it.
func restart() -> void:
	if can_restart():
		EditorInterface.call_deferred("restart_editor", false)


# The script editor reports an unsaved script by its text's version, as Godot's own
# unsaved mark does. Both lists below walk the same tabs in the same order, but a text
# file's tab has no script, so the names pair only when every tab holds one.
static func _unsaved_scripts() -> PackedStringArray:
	var script_editor := EditorInterface.get_script_editor()
	var editors: Array[ScriptEditorBase] = script_editor.get_open_script_editors()
	var scripts: Array[Script] = script_editor.get_open_scripts()
	var paired := scripts.size() == editors.size()
	var unsaved := PackedStringArray()
	for index: int in editors.size():
		var base: Control = editors[index].get_base_editor()
		if not base is TextEdit:
			continue
		var text_edit: TextEdit = base
		if text_edit.get_version() != text_edit.get_saved_version():
			unsaved.append(scripts[index].resource_path.get_file() if paired else "")
	return unsaved


# A scene never saved has a root with no file path. From 4.7 the path list also holds
# the empty tab the editor opens with, which has no root and would count as untitled.
# So from 4.5, where the editor lists the roots, the roots are read; before 4.5 the path
# list skips a tab with no root, and it is read instead.
static func _untitled_scenes() -> int:
	var count := 0
	if EditorInterface.has_method("get_open_scene_roots"):
		var roots: Array = EditorInterface.call("get_open_scene_roots")
		for root: Node in roots:
			if root.scene_file_path.is_empty():
				count += 1
		return count
	for path: String in EditorInterface.get_open_scenes():
		if path.is_empty():
			count += 1
	return count
