@tool
extends EditorExportPlugin
## Auto-strips godot_mcp_toolkit addon files, GDScript extensions, and
## res://.mcp.json from exported builds. C# extensions compile into .NET
## assemblies and cannot be stripped per-class — see docs/extending.md.
## Registered by plugin.gd; prevents MCP code shipping in game PCKs.

const _ADDON_PREFIX := "res://addons/godot_mcp_toolkit/"
const _MCP_JSON_PATH := "res://.mcp.json"

# Single source of truth for "what is an extension" — must match
# extension_loader.gd's _is_extension_candidate() GDScript check: an extension
# is a DIRECT subclass of MCPToolkitExtension. Multi-level inheritance is
# intentionally unsupported (and such orphan files are harmless in builds), so
# the strip is deliberately single-level too.
const _EXTENSION_BASE := "MCPToolkitExtension"

# COUPLING: Must match plugin.gd _enable_plugin()'s add_autoload_singleton() call.
const _AUTOLOAD_KEY := "autoload/MCPRuntimeServer"
const _AUTOLOAD_VAL := "*res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd"

# Built in _export_begin() from the global class list. Keys = res:// paths of
# GDScript extension files (direct subclasses of MCPToolkitExtension).
var _extension_strip_paths: Dictionary = {}


func _get_name() -> String:
	return "MCPExportStrip"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_extension_strip_paths = _compute_strip_paths(ProjectSettings.get_global_class_list())
	if ProjectSettings.has_setting(_AUTOLOAD_KEY):
		ProjectSettings.set_setting(_AUTOLOAD_KEY, null)


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_PREFIX):
		skip()
		return
	if path == _MCP_JSON_PATH:
		skip()
		return
	if _extension_strip_paths.has(path):
		skip()
		return


func _export_end() -> void:
	# Unconditional restore — self-heals if a prior export crashed mid-bake.
	ProjectSettings.set_setting(_AUTOLOAD_KEY, _AUTOLOAD_VAL)
	_extension_strip_paths.clear()


# ── Extension scan (pure; unit-tested in test/run_unit_tests.gd) ──────────
# Single-level by design — mirrors the loader's definition of an extension (a
# DIRECT subclass of MCPToolkitExtension). The engine flattens a path-based
# `extends "res://.../some_extension.gd"` to its named base, so direct
# subclasses written either way report base == MCPToolkitExtension and are
# caught. Multi-level chains (class two+ levels deep) are NOT extensions and
# ship as harmless orphans.
static func _compute_strip_paths(classes: Array) -> Dictionary:
	var strip := {}  # path → true
	for entry in classes:
		if entry.get("base", "") != _EXTENSION_BASE:
			continue
		var p: String = entry.get("path", "")
		if not p.is_empty() and p.ends_with(".gd"):
			strip[p] = true
	return strip
