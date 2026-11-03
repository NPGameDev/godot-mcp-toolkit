@tool
extends RefCounted
## Seam tests for the update folder's two protections: FileGuard refuses it to tool calls,
## through resolve_safe and the file tools, and the export strip (core/export_strip.gd) keeps
## it out of a build without counting it in leak detection. run() is a coroutine: each tool
## case awaits registry.call_command().

const Testing := preload("res://test/units/testing.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const ExportStrip := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd")
const AssetCommands := preload("res://addons/godot_mcp_toolkit/commands/asset_commands.gd")
const FolderCommands := preload("res://addons/godot_mcp_toolkit/commands/folder_commands.gd")
const ResourceCommands := preload("res://addons/godot_mcp_toolkit/commands/resource_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")

const _FOLDER := "res://addons/.godot_mcp_toolkit_update"
const _STRIP_SOURCE := "res://addons/godot_mcp_toolkit/core/export_strip.gd"


static func run(testing: Testing) -> void:
	_test_guard_reserves_this_folder(testing)
	_test_guard_refuses_every_entry(testing)
	_test_guard_refuses_spellings(testing)
	_test_guard_refuses_forms_refused_anywhere(testing)
	_test_guard_allows_look_alikes(testing)
	var registry := MCPToolkitCommandRegistry.new()
	AssetCommands.register(registry, null)
	FolderCommands.register(registry, null)
	ResourceCommands.register(registry, null)
	ScriptCommands.register(registry, null)
	await _test_tools_refuse_reads(testing, registry)
	await _test_tools_refuse_writes(testing, registry)
	_test_strip_skips_the_folder(testing)
	_test_strip_leaves_others_alone(testing)


static func _test_guard_reserves_this_folder(testing: Testing) -> void:
	testing.begin("Update folder: FileGuard reserves the folder this module writes")
	testing.eq(FileGuard.UPDATE_FOLDER, UpdateFolder.FOLDER, "both name the same folder")
	testing.ok(FileGuard.is_update_folder(UpdateFolder.stage_folder()), "the stage is inside it")
	testing.ok(FileGuard.is_update_folder(UpdateFolder.backup_folder("1.1.0")), "a backup is inside it")
	print("")


static func _test_guard_refuses_every_entry(testing: Testing) -> void:
	testing.begin("FileGuard.resolve_safe: the update folder and everything it holds")
	for path: String in [
		_FOLDER,
		_FOLDER + "/",
		_FOLDER + "/journal.json",
		_FOLDER + "/install.log",
		_FOLDER + "/.gitignore",
		_FOLDER + "/stage",
		_FOLDER + "/stage/",
		_FOLDER + "/stage/plugin.cfg",
		_FOLDER + "/stage/core/modules.gd",
		_FOLDER + "/backup-1.1.0",
		_FOLDER + "/backup-1.1.0/plugin.cfg",
		_FOLDER + "/1.2.0/release.zip",
	]:
		testing.eq(FileGuard.resolve_safe(path).get("error"), "PATH_DENIED", "'%s' → PATH_DENIED" % path)
	var refusal := str(FileGuard.resolve_safe(_FOLDER + "/journal.json").get("reason"))
	testing.ok(refusal.contains(".godot_mcp_toolkit_update"), "the refusal names the folder")
	print("")


static func _test_guard_refuses_spellings(testing: Testing) -> void:
	testing.begin("FileGuard.resolve_safe: the update folder in any spelling")
	for path: String in [
		"res://ADDONS/.GODOT_MCP_TOOLKIT_UPDATE/journal.json",
		"res://addons/.Godot_MCP_Toolkit_Update/stage/plugin.cfg",
		"res://ADDONS/.GODOT_MCP_TOOLKIT_UPDATE",
		"res://addon\u017f/.godot_mcp_toolkit_update/journal.json",
		"res://addons/.godot_mcp_toolk\u0131t_update/journal.json",
		"res://addons/.godot_mcp_tool\u212ait_update/journal.json",
		"res://addons/.godot_mcp_toolk\u0130t_update/journal.json",
		"res://./addons/.godot_mcp_toolkit_update/journal.json",
		"res://addons/./.godot_mcp_toolkit_update/stage/./plugin.cfg",
		"res://addons//.godot_mcp_toolkit_update//journal.json",
		"res://addons\\.godot_mcp_toolkit_update\\stage\\plugin.cfg",
		"res://addons\\.godot_mcp_toolkit_update\\",
		"res://addons/.godot_mcp_toolkit_update./journal.json",
		"res://addons/.godot_mcp_toolkit_update /journal.json",
		"res://addons/.godot_mcp_toolkit_update::$INDEX_ALLOCATION/journal.json",
		"res://addons/.godot_mcp_toolkit_update:stream",
	]:
		testing.eq(FileGuard.resolve_safe(path).get("error"), "PATH_DENIED", "'%s' → PATH_DENIED" % path)
	print("")


# Each of these forms has its own refusal in resolve_safe, whatever folder it names. They
# stay pinned here because each one would otherwise be a way into the update folder.
static func _test_guard_refuses_forms_refused_anywhere(testing: Testing) -> void:
	testing.begin("FileGuard.resolve_safe: the update folder through forms refused anywhere")
	var global_path := ProjectSettings.globalize_path(_FOLDER + "/journal.json")
	for path: String in [
		"res://addons/x/../.godot_mcp_toolkit_update/journal.json",
		_FOLDER + "/stage/../journal.json",
		"res:///addons/.godot_mcp_toolkit_update/journal.json",
		"RES://addons/.godot_mcp_toolkit_update/journal.json",
		"/addons/.godot_mcp_toolkit_update/journal.json",
		"C:/project/addons/.godot_mcp_toolkit_update/journal.json",
		"C:\\project\\addons\\.godot_mcp_toolkit_update\\journal.json",
		"\\\\server\\share\\addons\\.godot_mcp_toolkit_update\\journal.json",
		global_path,
		global_path.replace("/", "\\"),
		"res://addons/GODOT_~1/journal.json",
		"res://addons/godot_~2",
	]:
		testing.eq(FileGuard.resolve_safe(path).get("error"), "PATH_DENIED", "'%s' → PATH_DENIED" % path)
	print("")


static func _test_guard_allows_look_alikes(testing: Testing) -> void:
	testing.begin("FileGuard.resolve_safe: a look-alike of the update folder stays open")
	for path: String in [
		"res://addons/.godot_mcp_toolkit_update_x/",
		"res://addons/.godot_mcp_toolkit_update_x/journal.json",
		"res://addons/.godot_mcp_toolkit_updates/journal.json",
		"res://addons/godot_mcp_toolkit_update/journal.json",
		"res://.godot_mcp_toolkit_update/journal.json",
		"res://game/addons/.godot_mcp_toolkit_update/journal.json",
		"res://addons/other/.godot_mcp_toolkit_update/journal.json",
	]:
		testing.eq(FileGuard.resolve_safe(path).get("error"), null, "'%s' → allowed" % path)
	testing.eq(
			FileGuard.resolve_safe("user://addons/.godot_mcp_toolkit_update/x", ["user://"]).get("error"), null,
			"the same name under user:// → allowed")
	testing.ok(not FileGuard.is_toolkit_source(_FOLDER + "/stage/plugin.cfg"),
			"the update folder is not the toolkit's source, which the strip counts for leaks")
	print("")


# Every target is absent, so without the guard the tool answers NOT_FOUND.
static func _test_tools_refuse_reads(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("The file tools refuse a read of the update folder")
	var journal: Dictionary = await registry.call_command("script.read", {"file_path": _FOLDER + "/journal.json"})
	var upper_case: Dictionary = await registry.call_command("script.read", {"file_path": "res://ADDONS/.GODOT_MCP_TOOLKIT_UPDATE/stage/plugin.gd"})
	var resource: Dictionary = await registry.call_command("resource.load", {"file_path": _FOLDER + "/backup-1.1.0/theme.tres"})
	testing.eq(journal.get("code"), "PATH_DENIED", "script.read journal.json → PATH_DENIED")
	testing.eq(upper_case.get("code"), "PATH_DENIED", "script.read in upper case → PATH_DENIED")
	testing.eq(resource.get("code"), "PATH_DENIED", "resource.load in a backup → PATH_DENIED")
	print("")


# Past the guard, the script and resource writes stop on the target's extension or missing
# type before they touch the disk. folder.create and asset.import would write, so those
# cases clear whatever landed before they assert.
static func _test_tools_refuse_writes(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("The file tools refuse a write into the update folder")
	var folder_target := _FOLDER + "/stage/guard_test_absent"
	var folder_created: Dictionary = await registry.call_command("folder.create", {"path": folder_target})
	var folder_landed := DirAccess.dir_exists_absolute(folder_target)
	_clear_folder_target(folder_target)
	var script_written: Dictionary = await registry.call_command("script.write", {
		"file_path": _FOLDER + "/journal.json", "content": "{}"})
	var backslash_written: Dictionary = await registry.call_command("script.write", {
		"file_path": "res://addons\\.godot_mcp_toolkit_update\\journal.json", "content": "{}"})
	var resource_written: Dictionary = await registry.call_command("resource.write", {
		"file_path": _FOLDER + "/stage/guard_test_absent.tres"})
	var asset_target := _FOLDER + "/stage/guard_test_absent.png"
	var asset_imported: Dictionary = await registry.call_command("asset.import", {
		"base64_data": "AAAA", "dest_path": asset_target})
	if FileAccess.file_exists(asset_target):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(asset_target))
	_clear_folder_target(folder_target)
	testing.eq(folder_created.get("code"), "PATH_DENIED", "folder.create under stage/ → PATH_DENIED")
	testing.ok(not folder_landed, "folder.create under stage/ → no folder on disk")
	testing.eq(script_written.get("code"), "PATH_DENIED", "script.write journal.json → PATH_DENIED")
	testing.eq(backslash_written.get("code"), "PATH_DENIED", "script.write with backslashes → PATH_DENIED")
	testing.eq(resource_written.get("code"), "PATH_DENIED", "resource.write under stage/ → PATH_DENIED")
	testing.eq(asset_imported.get("code"), "PATH_DENIED", "asset.import under stage/ → PATH_DENIED")
	print("")


# remove_absolute refuses a folder that is not empty, so this can only clear what the case
# itself left behind.
static func _clear_folder_target(folder_target: String) -> void:
	var target := ProjectSettings.globalize_path(folder_target)
	for leftover: String in [target, target.get_base_dir(), target.get_base_dir().get_base_dir()]:
		if DirAccess.dir_exists_absolute(leftover):
			DirAccess.remove_absolute(leftover)


static func _test_strip_skips_the_folder(testing: Testing) -> void:
	testing.begin("Export strip: the update folder is skipped and left out of the leak flags")
	var strip: Variant = _strip_on_a_stand_in()
	if strip == null:
		testing.ok(false, "export_strip.gd compiles on the stand-in base")
		print("")
		return
	for path: String in [
		_FOLDER + "/journal.json",
		_FOLDER + "/stage/plugin.cfg",
		_FOLDER + "/stage/core/modules.gd",
		_FOLDER + "/backup-1.1.0/plugin.cfg",
		_FOLDER + "/backup-1.1.0/core/modules.gd",
		_FOLDER + "/1.2.0/release.zip",
		"res://ADDONS/.GODOT_MCP_TOOLKIT_UPDATE/stage/plugin.gd",
		"res://addons\\.godot_mcp_toolkit_update\\stage\\plugin.gd",
		"res://addons/./.godot_mcp_toolkit_update/stage/plugin.gd",
		"res://addons/.godot_mcp_toolk\u0131t_update/stage/plugin.gd",
		"res://addons/.godot_mcp_toolkit_update./stage/plugin.gd",
	]:
		testing.ok(_offer(strip, path), "'%s' → skipped" % path)
	# No public path reads the _saw_addon_* flags headless, so this reads them directly.
	var saw_script: bool = strip.get("_saw_addon_script")
	var saw_nonscript: bool = strip.get("_saw_addon_nonscript")
	testing.ok(not saw_script, "no path in it counts as an addon script")
	testing.ok(not saw_nonscript, "no path in it counts as an addon non-script")
	var decision: Dictionary = ExportStrip._decide_warning(saw_script, saw_nonscript, {}, {})
	testing.ok(not decision["warn"], "a build that offers only these paths → no leak warning")
	print("")


static func _test_strip_leaves_others_alone(testing: Testing) -> void:
	testing.begin("Export strip: the update-folder branch leaves other paths alone")
	var strip: Variant = _strip_on_a_stand_in()
	if strip == null:
		testing.ok(false, "export_strip.gd compiles on the stand-in base")
		print("")
		return
	for path: String in [
		"res://addons/.godot_mcp_toolkit_update_x/a.gd",
		"res://addons/.godot_mcp_toolkit_updates/a.gd",
		"res://addons/godot_mcp_toolkit_update/a.gd",
		"res://game/addons/.godot_mcp_toolkit_update/a.gd",
		"res://game/main.tscn",
	]:
		testing.ok(not _offer(strip, path), "'%s' → kept" % path)
	testing.ok(not bool(strip.get("_saw_addon_nonscript")), "none of them counts for leak detection")
	testing.ok(_offer(strip, "res://.mcp.json"), "res://.mcp.json → still skipped")
	testing.ok(_offer(strip, "res://addons/godot_mcp_toolkit/plugin.cfg"), "a toolkit file → still skipped")
	testing.ok(bool(strip.get("_saw_addon_nonscript")), "a toolkit file → still counts for leak detection")
	print("")


# Whether the plugin skipped the path when offered it, as the engine does.
static func _offer(strip: Variant, path: String) -> bool:
	var before: int = strip.get("skips")
	strip.call("_export_file", path, "", PackedStringArray())
	return int(strip.get("skips")) > before


# The units run with the editor hint off, where the engine refuses to instantiate
# EditorExportPlugin, and its skip() sets a flag no script can read. So this compiles the
# plugin's real source onto RefCounted with a skip() that counts: the engine's class is the
# only thing replaced. Returns null when the source no longer compiles that way.
static func _strip_on_a_stand_in() -> Variant:
	var source := FileAccess.get_file_as_string(_STRIP_SOURCE)
	if not source.contains("extends EditorExportPlugin"):
		return null
	var script := GDScript.new()
	script.source_code = source.replace("extends EditorExportPlugin", "extends RefCounted") \
			+ "\n\nvar skips := 0\n\n\nfunc skip() -> void:\n\tskips += 1\n"
	if script.reload() != OK:
		return null
	return script.new()
