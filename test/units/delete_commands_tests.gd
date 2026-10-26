@tool
extends RefCounted
## The delete commands (commands/file_, folder_, resource_, scene_ and script_commands.gd)
## refuse a reserved path before they look for it. The runner's res:// is this repo, so
## every target is a name that does not exist: if the guard regresses, the command answers
## NOT_FOUND and has nothing to delete. run() is a coroutine: each case awaits
## registry.call_command().

const Testing := preload("res://test/units/testing.gd")
const FileCommands := preload("res://addons/godot_mcp_toolkit/commands/file_commands.gd")
const FolderCommands := preload("res://addons/godot_mcp_toolkit/commands/folder_commands.gd")
const ResourceCommands := preload("res://addons/godot_mcp_toolkit/commands/resource_commands.gd")
const SceneCommands := preload("res://addons/godot_mcp_toolkit/commands/scene_commands.gd")
const ScriptCommands := preload("res://addons/godot_mcp_toolkit/commands/script_commands.gd")


static func run(testing: Testing) -> void:
	var registry := MCPToolkitCommandRegistry.new()
	FileCommands.register(registry, null)
	FolderCommands.register(registry, null)
	ResourceCommands.register(registry, null)
	SceneCommands.register(registry, null)
	ScriptCommands.register(registry, null)
	await _test_folder_delete_refuses_reserved(testing, registry)
	await _test_file_delete_refuses_reserved(testing, registry)
	await _test_typed_deletes_refuse_dot_folders(testing, registry)


static func _test_folder_delete_refuses_reserved(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("folder.delete refuses a folder under a reserved path")
	var in_git: Dictionary = await _delete_absent(registry, "folder.delete", "path",
			"res://.git/p7_07c_absent", {"recursive": true})
	testing.eq(in_git.get("code"), "PATH_DENIED", "res://.git/p7_07c_absent recursive → PATH_DENIED")
	var in_godot: Dictionary = await _delete_absent(registry, "folder.delete", "path",
			"res://.godot/p7_07c_absent", {})
	testing.eq(in_godot.get("code"), "PATH_DENIED", "res://.godot/p7_07c_absent → PATH_DENIED")
	print("")


static func _test_file_delete_refuses_reserved(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("file.delete refuses a file under a reserved path or named project.godot")
	var in_git: Dictionary = await _delete_absent(registry, "file.delete", "file_path",
			"res://.git/p7_07c_absent", {})
	testing.eq(in_git.get("code"), "PATH_DENIED", "res://.git/p7_07c_absent → PATH_DENIED")
	var project_file: Dictionary = await _delete_absent(registry, "file.delete", "file_path",
			"res://p7_07c_absent/project.godot", {})
	testing.eq(project_file.get("code"), "PATH_DENIED", "res://p7_07c_absent/project.godot → PATH_DENIED")
	print("")


# These commands accept only their own extensions, so each target carries the right one
# and is refused for its dot-folder alone.
static func _test_typed_deletes_refuse_dot_folders(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("resource.delete, scene.delete and script.delete refuse a file inside a dot-folder")
	var resource: Dictionary = await _delete_absent(registry, "resource.delete", "file_path",
			"res://.godot/p7_07c_absent.tres", {})
	testing.eq(resource.get("code"), "PATH_DENIED", "resource.delete res://.godot/p7_07c_absent.tres → PATH_DENIED")
	var scene: Dictionary = await _delete_absent(registry, "scene.delete", "file_path",
			"res://.git/p7_07c_absent.tscn", {})
	testing.eq(scene.get("code"), "PATH_DENIED", "scene.delete res://.git/p7_07c_absent.tscn → PATH_DENIED")
	var script: Dictionary = await _delete_absent(registry, "script.delete", "file_path",
			"res://.claude/p7_07c_absent.gd", {})
	testing.eq(script.get("code"), "PATH_DENIED", "script.delete res://.claude/p7_07c_absent.gd → PATH_DENIED")
	print("")


# Calls the command only while the target is absent, so this suite can never delete a
# real file or folder, whatever the guard does.
static func _delete_absent(
		registry: MCPToolkitCommandRegistry, method: String, path_key: String, path: String,
		extra_parameters: Dictionary,
) -> Dictionary:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return {"success": false, "code": "TARGET_EXISTS", "error": "test target exists: %s" % path}
	var parameters := extra_parameters.duplicate()
	parameters[path_key] = path
	return await registry.call_command(method, parameters)
