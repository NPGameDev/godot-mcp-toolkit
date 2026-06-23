@tool
extends RefCounted
## Engine-version comparison helpers for version-gated command registration.
##
## Provides is_at_least / is_at_most / is_version_in_range checks against
## the running engine version, used to gate commands by their min/max Godot
## version requirements.

## Latest version tested. Versions above this still run but log a notice.
const GODOT_TESTED_MAX_VERSION := "4.6"


## True when running under `godot --headless` (no display server).
## Use to gate tools that require a viewport or running game.
static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


static func get_engine_version_pair() -> String:
	var info := Engine.get_version_info()
	return "%d.%d" % [info["major"], info["minor"]]


static func is_at_least(engine_ver: String, min_ver: String) -> bool:
	return _compare(_parse(engine_ver), _parse(min_ver)) >= 0


static func is_at_most(engine_ver: String, max_ver: String) -> bool:
	return _compare(_parse(engine_ver), _parse(max_ver)) <= 0


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
	if a[0] != b[0]:
		return a[0] - b[0]
	return a[1] - b[1]
