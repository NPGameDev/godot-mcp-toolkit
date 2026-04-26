@tool
extends RefCounted
## Sidecar state file — persists runtime gate/profile state per-project.
##
## Lives at .godot/mcp_toolkit_state.json (gitignored, per-project).
## Claude Code does not watch .godot/ contents, so writes here do NOT
## trigger an MCP server restart. The auth response and config_reloaded
## notification deliver this state to the bridge directly.

const MCPFeatureRegistry := preload("res://addons/godot_mcp_toolkit/feature_registry.gd")

const _FILENAME := "mcp_toolkit_state.json"


static func get_path() -> String:
	return ProjectSettings.globalize_path("res://") + ".godot/" + _FILENAME


static func read() -> Dictionary:
	var path := get_path()
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_warning("[MCPStateFile] corrupt sidecar at %s — ignoring" % path)
		return {}
	return parsed


static func write(profile: String, gates: Dictionary) -> Error:
	var data := {"profile": profile, "gates": gates}
	return _atomic_write(data)


static func set_gate(env_var_name: String, enabled: bool) -> Error:
	var data := read()
	var gates: Dictionary = data.get("gates", {})
	# Seed missing gates/profile from PS to prevent partial sidecar writes.
	if gates.size() < MCPFeatureRegistry.all_features().size():
		var ps_gates := gates_from_ps()
		for key in ps_gates:
			if not gates.has(key):
				gates[key] = ps_gates[key]
	if str(data.get("profile", "")).is_empty():
		var p: int = ProjectSettings.get_setting(
			"mcp_toolkit/feature_gates/profile",
			MCPFeatureRegistry.PROFILE_STANDARD)
		match p:
			MCPFeatureRegistry.PROFILE_MINIMAL: data["profile"] = "minimal"
			MCPFeatureRegistry.PROFILE_POWER_USER: data["profile"] = "power_user"
			_: data["profile"] = "standard"
	gates[env_var_name] = enabled
	data["gates"] = gates
	return _atomic_write(data)


static func set_profile(profile: String) -> Error:
	var data := read()
	data["profile"] = profile
	return _atomic_write(data)


static func get_current_gates() -> Dictionary:
	var data := read()
	return data.get("gates", {})


static func get_profile() -> String:
	var data := read()
	return data.get("profile", "")


static func is_gate_enabled(env_var_name: String) -> bool:
	var gates := get_current_gates()
	return gates.get(env_var_name, false) == true


## Build a full gates dict with every known env var set to the given value.
static func build_gates_dict(value: bool) -> Dictionary:
	var gates := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = value
	return gates


## Build gates dict from current ProjectSettings bools.
static func gates_from_ps() -> Dictionary:
	var gates := {}
	for feature in MCPFeatureRegistry.all_features():
		var entry: Dictionary = MCPFeatureRegistry.get_entry(feature)
		gates[str(entry["env_var"])] = bool(ProjectSettings.get_setting(str(entry["ps_key"]), false))
	return gates


static func _atomic_write(data: Dictionary) -> Error:
	var path := get_path()
	# Ensure .godot/ directory exists (it should, but guard anyway).
	var dir_path := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		var err := DirAccess.make_dir_recursive_absolute(dir_path)
		if err != OK:
			push_warning("[MCPStateFile] cannot create directory %s (err %d)" % [dir_path, err])
			return err
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		var err := FileAccess.get_open_error()
		push_warning("[MCPStateFile] cannot write tmp file %s (err %d)" % [tmp_path, err])
		return err
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	# Atomic rename. On Windows, DirAccess.rename() handles overwrite.
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("[MCPStateFile] cannot open dir %s for rename" % dir_path)
		return ERR_FILE_CANT_OPEN
	var rename_err := dir.rename(tmp_path.get_file(), _FILENAME)
	if rename_err != OK:
		# Fallback: delete target then rename.
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		rename_err = dir.rename(tmp_path.get_file(), _FILENAME)
		if rename_err != OK:
			push_warning("[MCPStateFile] rename failed (err %d) — falling back to direct write" % rename_err)
			# Last resort: direct write (non-atomic).
			DirAccess.remove_absolute(tmp_path)
			f = FileAccess.open(path, FileAccess.WRITE)
			if f == null:
				return FileAccess.get_open_error()
			f.store_string(JSON.stringify(data, "\t"))
			f.close()
	return OK
