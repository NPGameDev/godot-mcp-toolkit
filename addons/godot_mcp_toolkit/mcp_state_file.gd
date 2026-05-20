@tool
extends RefCounted
## Sidecar state file — persists runtime gate state per-project.
##
## Lives at user://addons/godot_mcp_toolkit/project_instance_<hash>/
## mcp_toolkit_state.json (per-instance, survives .godot/ deletion).
## Claude Code does not watch user:// contents, so writes here do NOT
## trigger an MCP server restart. The auth response and config_reloaded
## notification deliver this state to the bridge directly.

const FeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/project_paths.gd")

const _FILENAME := "mcp_toolkit_state.json"


static func get_path() -> String:
	return ProjectPaths.instance_dir() + _FILENAME


static func read() -> Dictionary:
	var path := get_path()
	# Skip file_exists() — it can return stale true on Windows after a
	# failed rename-based write.  open(READ) is the authoritative check.
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_warning("[McpStateFile] corrupt sidecar at %s — ignoring" % path)
		return {}
	return parsed


static func write_gates(gates: Dictionary) -> Error:
	var data := {"gates": gates}
	return _atomic_write(data)


static func set_gate(env_var_name: String, enabled: bool) -> Error:
	var data := read()
	var gates: Dictionary = data.get("gates", {})
	# Seed missing gates from PS to prevent partial sidecar writes.
	if gates.size() < FeatureRegistry.all_features().size():
		var ps_gates := gates_from_ps()
		for key in ps_gates:
			if not gates.has(key):
				gates[key] = ps_gates[key]
	gates[env_var_name] = enabled
	data["gates"] = gates
	return _atomic_write(data)


static func get_current_gates() -> Dictionary:
	var data := read()
	return data.get("gates", {})



static func is_gate_enabled(env_var_name: String) -> bool:
	var gates := get_current_gates()
	return gates.get(env_var_name, false) == true


## Build a full gates dict with every known env var set to the given value.
static func build_gates_dict(value: bool) -> Dictionary:
	var gates := {}
	for feature in FeatureRegistry.all_features():
		var entry: Dictionary = FeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = value
	return gates


## Build gates dict from current ProjectSettings bools.
static func gates_from_ps() -> Dictionary:
	var gates := {}
	for feature in FeatureRegistry.all_features():
		var entry: Dictionary = FeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = bool(ProjectSettings.get_setting(str(entry["ps_key"]), false))
	return gates


static func _atomic_write(data: Dictionary) -> Error:
	var path := get_path()
	ProjectPaths.ensure_dirs()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_warning("[McpStateFile] cannot write %s (err %d)" % [path, err])
		return err
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK
