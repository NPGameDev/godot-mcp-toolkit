@tool
extends RefCounted
## Where the recovery plugin lives, and how it is put in place and taken away: the second
## editor plugin that exists only while an update is in flight, and puts the backup back at
## the next start when the installed version does not load.
##
## Its folder starts with a dot, so the Plugins list and the editor's file scan skip it,
## and the editor still enables it at start from the saved entry, which names its
## [code]plugin.cfg[/code] by its full path.[br]
## [br]
## [method install] and [method remove] write that entry in [code]project.godot[/code]
## themselves and read the file back: while the editor starts its plugins, enabling or
## disabling one saves nothing.

const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")

## The recovery plugin's [code]plugin.cfg[/code], as [code]editor_plugins/enabled[/code] in
## [code]project.godot[/code] names it.
const PLUGIN_CFG := "res://addons/.godot_mcp_toolkit_recovery/plugin.cfg"
## The folder the toolkit ships the recovery plugin in; each install copies it.
const TEMPLATE_FOLDER := "res://addons/godot_mcp_toolkit/self_update/recovery"
## What [method install] returns when a file of the plugin could not be written.
const COPY_FAILED := "the recovery plugin could not be copied"
## What [method install] returns when [code]project.godot[/code] on disk does not hold the
## saved entry after the save.
const SAVE_FAILED := "project.godot could not be saved"

const _PROJECT_FILE := "res://project.godot"
const _ENABLED_SETTING := "editor_plugins/enabled"
# `*` also matches the ignore file itself, so version control lists nothing in the folder.
const _IGNORE_FILES := [".gitignore", ".p4ignore"]

var _project_file: String = ""
var _folder: String = ""


## [param options] replaces what the files use, for tests: [code]project_file[/code], a
## project file edited directly instead of through the project settings, and
## [code]recovery_folder[/code], the folder the plugin is copied to.
func _init(options: Dictionary = {}) -> void:
	_project_file = str(options.get("project_file", ""))
	_folder = str(options.get("recovery_folder", PLUGIN_CFG.get_base_dir()))


## Copies the plugin from [constant TEMPLATE_FOLDER] with its ignore files, enables it in
## the editor, and saves its entry in [code]project.godot[/code].
##
## Returns an empty string once the folder is whole and the file on disk holds the entry,
## else [constant COPY_FAILED], with the entry left as it was, or [constant SAVE_FAILED].
func install() -> String:
	if not _copy_template():
		return COPY_FAILED
	if Engine.is_editor_hint() and not EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		EditorInterface.set_plugin_enabled(PLUGIN_CFG, true)
	return "" if _save_entry(true) else SAVE_FAILED


## Disables the plugin, drops its saved entry and deletes its folder, each as far as it
## goes.
##
## The disable waits for the next idle frame: called from inside the editor's own plugin
## teardown or start, it would otherwise change the editor's plugin list mid-change.
func remove() -> void:
	if Engine.is_editor_hint() and EditorInterface.is_plugin_enabled(PLUGIN_CFG):
		EditorInterface.set_plugin_enabled.call_deferred(PLUGIN_CFG, false)
	# A save that fails leaves the entry in project.godot with its folder gone, which costs
	# only the editor's warning at the next start that the addon failed to load, so it is
	# not reported.
	_save_entry(false)
	FolderFiles.remove_tree(ProjectSettings.globalize_path(_folder))


## Whether the folder holds every file [method install] copies and
## [code]project.godot[/code] on disk holds the entry.
func is_in_place() -> bool:
	var folder := ProjectSettings.globalize_path(_folder)
	for relative: String in _plugin_files():
		if not FileAccess.file_exists(folder.path_join(relative)):
			return false
	return is_entry_saved(_saved_project_file())


## Whether the project file at [param project_file] saves the recovery plugin's entry.
## The editor starts only the plugins the file on disk saves, so this reads the file,
## never the settings in memory. A file that does not load counts as no entry.
static func is_entry_saved(project_file: String) -> bool:
	return PLUGIN_CFG in _saved_entries(project_file)


# Copies over what is there, so a folder an interrupted install left becomes whole.
func _copy_template() -> bool:
	var files := _plugin_files()
	if files.is_empty():
		return false
	var folder := ProjectSettings.globalize_path(_folder)
	var template := ProjectSettings.globalize_path(TEMPLATE_FOLDER)
	for relative: String in files:
		var bytes := FileAccess.get_file_as_bytes(template.path_join(relative))
		if not FolderFiles.write_checked(folder.path_join(relative), bytes):
			return false
	for file_name: String in _IGNORE_FILES:
		if not FolderFiles.write_checked(folder.path_join(file_name), "*\n".to_utf8_buffer()):
			return false
	return true


# Writes the entry in or out, unless the file on disk already says so, then reads the file
# back. Returns whether the file now holds the entry exactly when `saved`.
func _save_entry(saved: bool) -> bool:
	var project_file := _saved_project_file()
	if is_entry_saved(project_file) == saved:
		return true
	if _project_file.is_empty():
		var enabled := _entries_of(ProjectSettings.get_setting(_ENABLED_SETTING, PackedStringArray()))
		ProjectSettings.set_setting(_ENABLED_SETTING, _with_entry(enabled, saved))
		ProjectSettings.save()
	else:
		var project := ConfigFile.new()
		if project.load(_project_file) == OK:
			var enabled := _entries_of(project.get_value("editor_plugins", "enabled", PackedStringArray()))
			project.set_value("editor_plugins", "enabled", _with_entry(enabled, saved))
			project.save(_project_file)
	return is_entry_saved(project_file) == saved


func _saved_project_file() -> String:
	return _project_file if not _project_file.is_empty() else _PROJECT_FILE


# The template's files without the .uid sidecars: a copied .uid would give two scripts one
# id, and nothing refers to the copies by uid.
static func _plugin_files() -> PackedStringArray:
	var files := PackedStringArray()
	for relative: String in FolderFiles.list(ProjectSettings.globalize_path(TEMPLATE_FOLDER)):
		if relative.get_extension() != "uid":
			files.append(relative)
	return files


static func _saved_entries(project_file: String) -> PackedStringArray:
	var project := ConfigFile.new()
	if project.load(project_file) != OK:
		return PackedStringArray()
	return _entries_of(project.get_value("editor_plugins", "enabled", PackedStringArray()))


static func _entries_of(value: Variant) -> PackedStringArray:
	var entries := PackedStringArray()
	if value is PackedStringArray or value is Array:
		for entry: Variant in value:
			entries.append(str(entry))
	return entries


static func _with_entry(enabled: PackedStringArray, saved: bool) -> PackedStringArray:
	var entries := PackedStringArray()
	for entry: String in enabled:
		if entry != PLUGIN_CFG:
			entries.append(entry)
	# The editor saves this list sorted and starts the plugins in its order. Last, the entry
	# would come after the toolkit's, whose start can delete this folder before the editor
	# reaches it; sorted, the dot folder comes first, as the editor itself would save it.
	if saved:
		entries.append(PLUGIN_CFG)
		entries.sort()
	return entries
