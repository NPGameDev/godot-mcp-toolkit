@tool
extends RefCounted
## project.* command handlers — get_settings, set_setting.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCoerce = _Hub.MCPCoerce
const MCPUntrusted = _Hub.MCPUntrusted
const MCPFeatureGate = _Hub.MCPFeatureGate

const SECRET_KEY_REGEX := "(?i)password|token|secret|key"


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("project.get_settings", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_get_settings(parameters))
	registry.add("project.set_setting", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_set_setting(parameters))
	registry.add("autoload.manage", func(parameters: Dictionary) -> Dictionary:
		return _cmd_autoload_manage(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_project_get_settings(parameters: Dictionary) -> Dictionary:
	var prefix := str(parameters.get("prefix", ""))

	var regex := RegEx.new()
	var compile_error := regex.compile(SECRET_KEY_REGEX)
	if compile_error != OK:
		return MCPError.make("INTERNAL",
			"secret regex failed to compile (err %d)" % compile_error)

	var settings := {}
	var filtered_secrets := 0
	for property in ProjectSettings.get_property_list():
		var property_name := str(property.get("name", ""))
		if property_name.is_empty() or not property_name.contains("/"):
			continue
		if not prefix.is_empty() and not property_name.begins_with(prefix):
			continue
		if regex.search(property_name) != null:
			filtered_secrets += 1
			continue
		settings[property_name] = MCPCoerce.serialize_value(
			ProjectSettings.get_setting(property_name))

	return {
		"settings": MCPUntrusted.wrap(
			"project_settings", "godot", JSON.stringify(settings)),
		"count": settings.size(),
		"filtered_secret_count": filtered_secrets,
	}


static func _cmd_project_set_setting(parameters: Dictionary) -> Dictionary:
	var key := str(parameters.get("setting", ""))
	if key.is_empty():
		return MCPError.make("INVALID_PARAMS", "setting must be a non-empty string")
	if key.begins_with("mcp_toolkit/"):
		return MCPError.make("INVALID_PATH",
			"refusing to write mcp_toolkit/* from project.set_setting (those are the toolkit's own settings — use the FeatureGate system or dock UI); got key=%s" % key)
	if key.begins_with("mcp/"):
		return MCPError.make("INVALID_PATH",
			"refusing to write mcp/* from project.set_setting (use the FeatureGate system); got key=%s" % key)
	if key.begins_with("editor/"):
		return MCPError.make("INVALID_PATH",
			"refusing to write editor/* ProjectSettings from project.set_setting (editor-session state, not project config); got key=%s" % key)
	if not parameters.has("value"):
		return MCPError.make("INVALID_PARAMS", "missing value")
	var raw_value = parameters.get("value", null)
	# Resource-typed values in raw_value are gated through FileGuard
	# via MCPCoerce.coerce_value's Resource branch.
	var coerced = MCPCoerce.coerce_value(raw_value)
	var was_set_before := ProjectSettings.has_setting(key)
	var previous_value = ProjectSettings.get_setting(key) if was_set_before else null
	ProjectSettings.set_setting(key, coerced)
	var save_error := ProjectSettings.save()
	if save_error != OK:
		return MCPError.make("SAVE_FAILED",
			"ProjectSettings.save returned %d (key=%s); change is in-memory but not persisted" % [
				save_error, key])
	var response := {
		"success": true,
		"key": key,
		"value": MCPCoerce.serialize_value(coerced),
		"was_set_before": was_set_before,
		"previous_value": MCPCoerce.serialize_value(previous_value) if was_set_before else null,
	}
	if key.begins_with("autoload/"):
		# Targeted update_file() on the autoload script path so the editor
		# indexes the file immediately — no need for a full scan().
		var autoload_value := str(coerced)
		var script_path := autoload_value.lstrip("*")
		if script_path.begins_with("res://"):
			var filesystem := EditorInterface.get_resource_filesystem()
			if filesystem != null:
				filesystem.update_file(script_path)
		response["hint"] = "Autoload registered in project.godot. The editor's autoload cache won't refresh until the project is reloaded — reference via get_node('/root/Name') instead of the global identifier. The game process picks up autoloads on next launch."
	return response


static func _cmd_autoload_manage(parameters: Dictionary) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return MCPError.make("INVALID_PARAMS", "missing action (register|unregister|list)")

	match action:
		"register":
			var aname := str(parameters.get("name", ""))
			var script_path := str(parameters.get("script_path", ""))
			if aname.is_empty() or script_path.is_empty():
				return MCPError.make("INVALID_PARAMS",
					"register requires name and script_path")
			if not script_path.begins_with("res://"):
				return MCPError.make("INVALID_PATH",
					"script_path must start with res:// (got %s)" % script_path)
			if not FileAccess.file_exists(script_path):
				return MCPError.make("NOT_FOUND",
					"script not found: %s; create it with script_write first" % script_path)
			var enabled := bool(parameters.get("enabled", true))
			var value := ("*" if enabled else "") + script_path
			ProjectSettings.set_setting("autoload/" + aname, value)
			var save_error := ProjectSettings.save()
			if save_error != OK:
				return MCPError.make("SAVE_FAILED",
					"ProjectSettings.save returned %d" % save_error)
			var filesystem := EditorInterface.get_resource_filesystem()
			if filesystem != null:
				filesystem.update_file(script_path)
			return {"success": true, "action": "register", "name": aname,
				"script_path": script_path, "enabled": enabled,
				"hint": "Autoload registered. The game process picks up autoloads on next launch. Reference via get_node('/root/%s')." % aname}

		"unregister":
			var aname := str(parameters.get("name", ""))
			if aname.is_empty():
				return MCPError.make("INVALID_PARAMS", "unregister requires name")
			var key := "autoload/" + aname
			if not ProjectSettings.has_setting(key):
				return MCPError.make("NOT_FOUND",
					"no autoload named '%s' in project settings" % aname)
			ProjectSettings.clear(key)
			var save_error := ProjectSettings.save()
			if save_error != OK:
				return MCPError.make("SAVE_FAILED",
					"ProjectSettings.save returned %d" % save_error)
			return {"success": true, "action": "unregister", "name": aname}

		"list":
			var autoloads: Array = []
			for property in ProjectSettings.get_property_list():
				var property_name := str(property.get("name", ""))
				if not property_name.begins_with("autoload/"):
					continue
				var aname := property_name.substr("autoload/".length())
				var raw_value := str(ProjectSettings.get_setting(property_name))
				var enabled := raw_value.begins_with("*")
				var path := raw_value.lstrip("*")
				autoloads.append({"name": aname, "script_path": path, "enabled": enabled})
			return {"success": true, "action": "list", "autoloads": autoloads,
				"count": autoloads.size()}

		_:
			return MCPError.make("INVALID_PARAMS",
				"unknown action '%s'; must be register|unregister|list" % action)
