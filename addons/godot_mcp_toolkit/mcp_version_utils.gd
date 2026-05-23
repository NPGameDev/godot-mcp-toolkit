@tool
extends RefCounted
## Centralized engine version helpers for version-gated tools.
##
## Used by command_registry.gd and extension_loader.gd to filter
## commands that require a specific Godot version range.

static func get_engine_version_pair() -> String:
	var info := Engine.get_version_info()
	return "%d.%d" % [info["major"], info["minor"]]


static func is_version_in_range(engine_ver: String, min_ver: String, max_ver: String) -> bool:
	var engine := _parse(engine_ver)
	if min_ver != "" and _compare(engine, _parse(min_ver)) < 0:
		return false
	if max_ver != "" and _compare(engine, _parse(max_ver)) > 0:
		return false
	return true


static func _parse(v: String) -> Array[int]:
	var parts := v.split(".")
	return [int(parts[0]) if parts.size() > 0 else 0,
			int(parts[1]) if parts.size() > 1 else 0]


static func _compare(a: Array[int], b: Array[int]) -> int:
	if a[0] != b[0]: return a[0] - b[0]
	return a[1] - b[1]
