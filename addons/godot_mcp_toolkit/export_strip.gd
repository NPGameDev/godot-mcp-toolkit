@tool
extends EditorExportPlugin
## Auto-strips all godot_mcp_toolkit addon files from exported builds.
## Registered by plugin.gd; prevents MCP code from shipping in game PCKs.

const _ADDON_PREFIX := "res://addons/godot_mcp_toolkit/"


func _get_name() -> String:
	return "MCPExportStrip"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_PREFIX):
		skip()
