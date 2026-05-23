@tool
extends EditorExportPlugin
## Auto-strips all godot_mcp_toolkit addon files from exported builds.
## Registered by plugin.gd; prevents MCP code from shipping in game PCKs.

const _ADDON_PREFIX := "res://addons/godot_mcp_toolkit/"

# COUPLING: Must match plugin.gd _enable_plugin()'s add_autoload_singleton() call.
const _AUTOLOAD_KEY := "autoload/MCPRuntimeServer"
const _AUTOLOAD_VAL := "*res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"


func _get_name() -> String:
	return "MCPExportStrip"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_PREFIX):
		skip()


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if ProjectSettings.has_setting(_AUTOLOAD_KEY):
		ProjectSettings.set_setting(_AUTOLOAD_KEY, null)


func _export_end() -> void:
	# Unconditional restore — self-heals if a prior export crashed mid-bake.
	ProjectSettings.set_setting(_AUTOLOAD_KEY, _AUTOLOAD_VAL)
