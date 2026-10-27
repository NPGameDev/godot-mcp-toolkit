@tool
extends RefCounted
## The save.* commands (commands/save_commands.gd) refuse the plugin's user folder through
## FileGuard.resolve_safe_user (security/file_guard.gd) under any letter case. Every target
## is a name that does not exist, so a regressed guard has nothing to read or list.
## run() is a coroutine: each case awaits registry.call_command().

const Testing := preload("res://test/units/testing.gd")
const SaveCommands := preload("res://addons/godot_mcp_toolkit/commands/save_commands.gd")


static func run(testing: Testing) -> void:
	var registry := MCPToolkitCommandRegistry.new()
	SaveCommands.register(registry, null)
	await _test_save_reads_refuse_plugin_folder_in_any_case(testing, registry)


static func _test_save_reads_refuse_plugin_folder_in_any_case(testing: Testing, registry: MCPToolkitCommandRegistry) -> void:
	testing.begin("save.read and save.list refuse the plugin's user folder in any letter case")
	var read: Dictionary = await _call_absent(registry, "save.read",
			"user://Addons/Godot_MCP_Toolkit/p7_08e_absent")
	testing.eq(read.get("code"), "PATH_DENIED", "save.read user://Addons/Godot_MCP_Toolkit/p7_08e_absent → PATH_DENIED")
	var listing: Dictionary = await _call_absent(registry, "save.list",
			"user://ADDONS/GODOT_MCP_TOOLKIT/p7_08e_absent/")
	testing.eq(listing.get("code"), "PATH_DENIED", "save.list user://ADDONS/GODOT_MCP_TOOLKIT/p7_08e_absent/ → PATH_DENIED")
	print("")


# Calls the command only while the target is absent, so this suite never reads a real
# token or audit log, whatever the guard does.
static func _call_absent(registry: MCPToolkitCommandRegistry, method: String, path: String) -> Dictionary:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return {"success": false, "code": "TARGET_EXISTS", "error": "test target exists: %s" % path}
	return await registry.call_command(method, {"path": path})
