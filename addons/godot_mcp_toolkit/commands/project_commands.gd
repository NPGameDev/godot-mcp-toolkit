@tool
extends RefCounted
class_name ProjectCommands
## project.* command handlers — get_settings, set_setting.

const SECRET_KEY_REGEX := "(?i)password|token|secret|key"


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("project.get_settings", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_get_settings(parameters), "lite")
	registry.add("project.set_setting", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_set_setting(parameters), "full")


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
		"settings": settings,
		"count": settings.size(),
		"filtered_secret_count": filtered_secrets,
	}


static func _cmd_project_set_setting(parameters: Dictionary) -> Dictionary:
	# TODO(iter-19): wrap in FeatureGate.is_enabled("project_set_setting").
	var key := str(parameters.get("key", ""))
	if key.is_empty():
		return MCPError.make("INVALID_PARAMS", "key must be a non-empty string")
	if key.begins_with("mcp/unsafe/"):
		return MCPError.make("INVALID_PATH",
			"refusing to write mcp/unsafe/* from project.set_setting (those are the toolkit's own gates — use the FeatureGate system in iter 19); got key=%s" % key)
	if key.begins_with("editor/"):
		return MCPError.make("INVALID_PATH",
			"refusing to write editor/* ProjectSettings from project.set_setting (editor-session state, not project config); got key=%s" % key)
	if not parameters.has("value"):
		return MCPError.make("INVALID_PARAMS", "missing value")
	var raw_value = parameters.get("value", null)
	# TODO(iter-18): route through FileGuard.resolve_safe at this site.
	var coerced = MCPCoerce.coerce_value(raw_value)
	var was_set_before := ProjectSettings.has_setting(key)
	var previous_value = ProjectSettings.get_setting(key) if was_set_before else null
	ProjectSettings.set_setting(key, coerced)
	var save_error := ProjectSettings.save()
	if save_error != OK:
		return MCPError.make("SAVE_FAILED",
			"ProjectSettings.save returned %d (key=%s); change is in-memory but not persisted" % [
				save_error, key])
	return {
		"success": true,
		"key": key,
		"value": MCPCoerce.serialize_value(coerced),
		"was_set_before": was_set_before,
		"previous_value": MCPCoerce.serialize_value(previous_value) if was_set_before else null,
	}
