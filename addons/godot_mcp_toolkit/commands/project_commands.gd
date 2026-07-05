@tool
extends RefCounted
## project.* command handlers — get_settings, set_setting, layer names.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const Coerce = Modules.Coerce
const Untrusted = Modules.Untrusted

const SECRET_KEY_REGEX := "(?i)password|token|secret|key"
const _VALID_LAYER_CATEGORIES := ["2d_physics", "2d_render", "3d_physics", "3d_render"]


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("project.get_settings", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_get_settings(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("project.set_setting", func(parameters: Dictionary) -> Dictionary:
		return _cmd_project_set_setting(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("autoload.manage", func(parameters: Dictionary) -> Dictionary:
		return _cmd_autoload_manage(parameters, _server)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("project.get_layer_names", func(parameters: Dictionary) -> Dictionary:
		return _cmd_get_layer_names(parameters)
	, MCPToolkitCommandOptions.new().mark_read_only().mark_scene_independent())
	registry.add("project.set_layer_names", func(parameters: Dictionary) -> Dictionary:
		return _cmd_set_layer_names(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_project_get_settings(parameters: Dictionary) -> Dictionary:
	var prefix := str(parameters.get("prefix", ""))

	var regex := RegEx.new()
	var compile_error := regex.compile(SECRET_KEY_REGEX)
	if compile_error != OK:
		return MCPToolkitError.fail("INTERNAL",
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
		settings[property_name] = Coerce.serialize_value(
			ProjectSettings.get_setting(property_name))

	return MCPToolkitSuccess.ok({
		"settings": Untrusted.wrap(
			"project_settings", "godot", JSON.stringify(settings)),
		"count": settings.size(),
		"filtered_secret_count": filtered_secrets,
	})


static func _cmd_project_set_setting(parameters: Dictionary) -> Dictionary:
	var key := str(parameters.get("setting", ""))
	if key.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "setting must be a non-empty string")
	# The `mcp_toolkit/limits/*` slice has a dedicated writer — meta.set_limits —
	# which applies floor clamps. Refusing the whole prefix here keeps that the
	# single sanctioned path for toolkit settings (rest go through the dock UI).
	if key.begins_with("mcp_toolkit/"):
		return MCPToolkitError.fail("INVALID_PATH",
			"refusing to write mcp_toolkit/* from project.set_setting (those are the toolkit's own settings — use the dock UI); got key=%s" % key)
	if key.begins_with("mcp/"):
		return MCPToolkitError.fail("INVALID_PATH",
			"refusing to write mcp/* from project.set_setting (those are the toolkit's internal settings); got key=%s" % key)
	if key.begins_with("editor/"):
		return MCPToolkitError.fail("INVALID_PATH",
			"refusing to write editor/* ProjectSettings from project.set_setting (editor-session state, not project config); got key=%s" % key)
	# Autoload guard — registration/unregistration must go through autoload_manage
	# so the editor's singleton cache refreshes immediately.
	if key.begins_with("autoload/"):
		var _al_raw = parameters.get("value", null)
		var _al_str := str(_al_raw) if _al_raw != null else ""
		var _al_name := key.substr("autoload/".length())
		# Registration attempt: value looks like a script path.
		if _al_str.begins_with("*res://") or _al_str.begins_with("res://"):
			return MCPToolkitError.fail("INVALID_PARAMS",
				"Use autoload_manage (action='register', name='%s', script_path='%s') instead of project.set_setting for autoload registration. project.set_setting bypasses the editor's autoload cache, causing unresolved identifier errors until the project is reloaded." % [_al_name, _al_str.lstrip("*")])
		# Unregistration attempt: null, empty, or missing value.
		if _al_raw == null or _al_str.is_empty():
			return MCPToolkitError.fail("INVALID_PARAMS",
				"Use autoload_manage (action='unregister', name='%s') instead of project.set_setting for autoload removal. project.set_setting bypasses the editor's autoload cache." % _al_name)
	if not parameters.has("value"):
		return MCPToolkitError.fail("INVALID_PARAMS", "missing value")
	var raw_value = parameters.get("value", null)
	# Resource-typed values in raw_value are gated through FileGuard
	# via Coerce.coerce_value's Resource branch.
	var coerced = Coerce.coerce_value(raw_value)
	if typeof(coerced) == TYPE_DICTIONARY and (coerced as Dictionary).has("_coerce_error"):
		return MCPToolkitError.fail("INVALID_PARAMS", str(coerced["_coerce_error"]))
	var was_set_before := ProjectSettings.has_setting(key)
	var previous_value = ProjectSettings.get_setting(key) if was_set_before else null
	ProjectSettings.set_setting(key, coerced)
	var save_error := ProjectSettings.save()
	if save_error != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ProjectSettings.save returned %d (key=%s); change is in-memory but not persisted" % [
				save_error, key])
	var response := {
		"key": key,
		"value": Coerce.serialize_value(coerced),
		"was_set_before": was_set_before,
		"previous_value": Coerce.serialize_value(previous_value) if was_set_before else null,
	}
	if key.begins_with("autoload/"):
		response["warning"] = "Modifying autoload/* via project.set_setting — the editor cache won't refresh. Consider using autoload_manage instead."
	return MCPToolkitSuccess.ok(response)


static func _cmd_autoload_manage(parameters: Dictionary, server: Node = null) -> Dictionary:
	var action := str(parameters.get("action", ""))
	if action.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing action (register|unregister|list)")

	match action:
		"register":
			var aname := str(parameters.get("name", ""))
			var script_path := str(parameters.get("script_path", ""))
			if aname.is_empty() or script_path.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS",
					"register requires name and script_path")
			if not script_path.begins_with("res://"):
				return MCPToolkitError.fail("INVALID_PATH",
					"script_path must start with res:// (got %s)" % script_path)
			if not FileAccess.file_exists(script_path):
				return MCPToolkitError.fail("NOT_FOUND",
					"script not found: %s; create it with script_write first" % script_path)
			var enabled := bool(parameters.get("enabled", true))
			var value := ("*" if enabled else "") + script_path
			# Use EditorPlugin API for immediate editor cache refresh.
			var plugin: EditorPlugin = server.get("editor_plugin") if server != null else null
			if plugin != null and enabled:
				plugin.add_autoload_singleton(aname, script_path)
			else:
				ProjectSettings.set_setting("autoload/" + aname, value)
				var save_error := ProjectSettings.save()
				if save_error != OK:
					return MCPToolkitError.fail("SAVE_FAILED",
						"ProjectSettings.save returned %d" % save_error)
				# Emit settings_changed so GDScriptParser refreshes its compile
				# cache (add_autoload_singleton does this internally; the direct
				# ProjectSettings path does not).
				ProjectSettings.emit_signal("settings_changed")
			var filesystem := EditorInterface.get_resource_filesystem()
			if filesystem != null:
				filesystem.update_file(script_path)
			return MCPToolkitSuccess.ok({"action": "register", "name": aname,
				"script_path": script_path, "enabled": enabled,
				"hint": "Autoload registered and editor cache updated. Reference via get_node('/root/%s')." % aname})

		"unregister":
			var aname := str(parameters.get("name", ""))
			if aname.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "unregister requires name")
			var key := "autoload/" + aname
			if not ProjectSettings.has_setting(key):
				return MCPToolkitError.fail("NOT_FOUND",
					"no autoload named '%s' in project settings" % aname)
			# Use EditorPlugin API for immediate editor cache refresh.
			var plugin: EditorPlugin = server.get("editor_plugin") if server != null else null
			if plugin != null:
				plugin.remove_autoload_singleton(aname)
			else:
				ProjectSettings.clear(key)
				var save_error := ProjectSettings.save()
				if save_error != OK:
					return MCPToolkitError.fail("SAVE_FAILED",
						"ProjectSettings.save returned %d" % save_error)
				ProjectSettings.emit_signal("settings_changed")
			return MCPToolkitSuccess.ok({"action": "unregister", "name": aname})

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
			return MCPToolkitSuccess.ok({"action": "list", "autoloads": autoloads,
				"count": autoloads.size()})

		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"unknown action '%s'; must be register|unregister|list" % action)


## Validate the layer category param. Returns null when valid, an
## MCPToolkitError dict otherwise.
static func _validate_layer_category(category: String) -> Variant:
	if category.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "missing category")
	if not category in _VALID_LAYER_CATEGORIES:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"invalid category '%s'; must be one of: %s" % [
				category, ", ".join(_VALID_LAYER_CATEGORIES)])
	return null


static func _cmd_get_layer_names(parameters: Dictionary) -> Dictionary:
	var category := str(parameters.get("category", ""))
	var cat_err = _validate_layer_category(category)
	if cat_err != null:
		return cat_err

	var layers := {}
	for n in range(1, 33):
		var key := "layer_names/%s/layer_%d" % [category, n]
		if ProjectSettings.has_setting(key):
			var name: String = str(ProjectSettings.get_setting(key))
			if not name.is_empty():
				layers[n] = name
	return MCPToolkitSuccess.ok({"category": category, "layers": layers})


static func _cmd_set_layer_names(parameters: Dictionary) -> Dictionary:
	var category := str(parameters.get("category", ""))
	var cat_err = _validate_layer_category(category)
	if cat_err != null:
		return cat_err

	var raw_layers = parameters.get("layers", null)
	if raw_layers == null or typeof(raw_layers) != TYPE_DICTIONARY:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"layers must be a dictionary mapping layer numbers (1-32) to names")

	var layers_dict: Dictionary = raw_layers
	for raw_key in layers_dict:
		var n: int = int(raw_key)
		if n < 1 or n > 32:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"layer number %s out of range; must be 1-32" % str(raw_key))

	var count := 0
	for raw_key in layers_dict:
		var n: int = int(raw_key)
		var layer_name: String = str(layers_dict[raw_key])
		var key := "layer_names/%s/layer_%d" % [category, n]
		ProjectSettings.set_setting(key, layer_name)
		count += 1

	var save_error := ProjectSettings.save()
	if save_error != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ProjectSettings.save returned %d; changes are in-memory but not persisted" % save_error)
	return MCPToolkitSuccess.ok({"layers_set": count})
