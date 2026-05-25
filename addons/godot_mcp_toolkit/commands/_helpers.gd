@tool
extends RefCounted
## Shared helpers used across multiple command handlers.
## Eliminates duplication of scene-node resolution, class hierarchy
## checks, file deletion, directory creation, log-level detection,
## and profile string conversion.

## NOTE: This file is preloaded by _hub.gd, so it CANNOT import _hub.gd
## (circular dependency). Use direct preloads for dependencies instead.
const McpError := preload("res://addons/godot_mcp_toolkit/mcp_error.gd")
const Coerce := preload("res://addons/godot_mcp_toolkit/_coerce.gd")


# -- Property coercion ---------------------------------------------------------


## Validate and coerce a raw JSON value for setting on a node property.
## Returns {"ok": true, "value": <coerced>} on success.
## Returns {"ok": false, "code": String, "error": String} on failure.
## Auto-coerces String → NodePath when the existing property value is NodePath.
## Rejects unknown property names (not in the instance's property list).
static func coerce_for_property(
	node: Object, property_name: String, raw_value: Variant,
) -> Dictionary:
	if not _has_property(node, property_name):
		return {"ok": false, "code": "PROPERTY_NOT_FOUND",
			"error": "property '%s' not found on %s" % [property_name, node.get_class()]}

	var missing := Coerce.check_resource_paths(raw_value)
	if missing != "":
		return {"ok": false, "code": "LOAD_FAILED",
			"error": "resource not found: %s" % missing}

	var coerced = Coerce.coerce_value(raw_value)

	if typeof(coerced) == TYPE_DICTIONARY \
			and (coerced as Dictionary).has("_coerce_error"):
		return {"ok": false, "code": "INVALID_VALUE",
			"error": str(coerced["_coerce_error"])}

	var old_value = node.get(property_name)
	if typeof(old_value) == TYPE_NODE_PATH and typeof(coerced) == TYPE_STRING:
		coerced = NodePath(str(coerced))

	return {"ok": true, "value": coerced}


## Compile a regex text_filter. Returns [RegEx-or-null, error-or-null, warning].
## Handles double-escaped metacharacters from MCP transport.
static func compile_text_filter(parameters: Dictionary) -> Array:
	var text_filter: String = str(parameters.get("text_filter", ""))
	var is_regex: bool = bool(parameters.get("is_regex", false))
	if text_filter == "" or not is_regex:
		return [null, null, ""]
	var regex := RegEx.new()
	if regex.compile("(?i)" + text_filter) != OK:
		var err := McpError.make("INVALID_PARAMS",
			"text_filter is not a valid regex (is_regex=true). "
			+ "To search for literal text, omit is_regex or set it to false. "
			+ "For regex, check for unbalanced groups () [] or unescaped metacharacters.")
		return [null, err, ""]
	var warning := _detect_double_escaped_regex(text_filter)
	return [regex, null, warning]


## Detect likely double-escaped regex metacharacters.
## Checks both single (\\d) and double (\\\\d) levels of over-escaping.
static func _detect_double_escaped_regex(pattern: String) -> String:
	for letter in ["d", "D", "w", "W", "s", "S", "b", "B"]:
		if pattern.find("\\\\\\\\" + letter) >= 0:
			return (
				"Pattern contains '\\\\\\\\%s' (multiple layers of backslash escaping). "
				+ "The regex metacharacter \\%s is over-escaped — use a POSIX "
				+ "character class instead (e.g. [0-9] for \\d, [a-zA-Z0-9_] for \\w)."
			) % [letter, letter, letter]
		if pattern.find("\\\\" + letter) >= 0:
			return (
				"Pattern contains '\\\\%s' (literal backslash + '%s'). "
				+ "If you meant the regex metacharacter \\%s, your backslash "
				+ "is likely double-escaped. Use a POSIX character class instead "
				+ "(e.g. [0-9] for \\d, [a-zA-Z0-9_] for \\w)."
			) % [letter, letter, letter]
	return ""


## Coerce and set a property on a node, handling compound paths (: and /)
## and dedicated setter APIs (shader_parameter/ on ShaderMaterial).
## Returns {"ok": true} on success, {"ok": false, "code": ..., "error": ...}
## on failure. Success results include an "_undo" key with info for the caller
## to register UndoRedo (type, effective path, old value, old resource refs).
##
## When make_unique is true and the target sub-resource is external (.tres),
## it is automatically duplicated as an inline copy before setting.
## This replicates the Inspector's "Make Unique" behavior.
##
## Path types:
##   No colon  — set directly on node (slash paths handled by Godot's _set).
##   Single :  — convert to / for node-level override (persists in .tscn).
##   Multi :   — manual sub-resource navigation; inline OK, external rejected
##              unless make_unique is set.
static func set_property_compound(
	node: Object, property_name: String, raw_value: Variant,
	make_unique: bool = false,
) -> Dictionary:
	# --- Coerce (shared by all paths) ---
	var missing := Coerce.check_resource_paths(raw_value)
	if missing != "":
		return {"ok": false, "code": "LOAD_FAILED",
			"error": "resource not found: %s" % missing}
	var coerced = Coerce.coerce_value(raw_value)
	if typeof(coerced) == TYPE_DICTIONARY \
			and (coerced as Dictionary).has("_coerce_error"):
		return {"ok": false, "code": "INVALID_VALUE",
			"error": str(coerced["_coerce_error"])}

	# --- No colon: set directly on node ---
	if ":" not in property_name:
		var _undo_old = node.get(property_name)
		node.set(property_name, coerced)
		var result := _check_set_readback(node, property_name, coerced, property_name)
		if result.get("ok", false):
			result["_undo"] = {"type": "property", "path": property_name, "old": _undo_old}
		return result

	var parts := property_name.split(":")

	# --- Navigate sub-resource chain (all colon paths) ---
	# For both single-colon and multi-colon, navigate to the target
	# sub-resource. When make_unique is set, duplicate EACH external
	# resource in the chain from the node down — this prevents
	# accidentally modifying shared .tres resources at any level.
	# Capture the original resource BEFORE make_unique for undo.
	var _undo_old_resource: Variant = null
	if make_unique and parts.size() >= 2:
		_undo_old_resource = node.get(parts[0])

	var target: Object = node
	var made_unique: Array = []  # Track which resources were duplicated.
	for i in range(parts.size() - 1):
		var sub = target.get(parts[i])
		if sub == null or not (sub is Object):
			return {"ok": false, "code": "NOT_FOUND",
				"error": "sub-resource '%s' is null on %s" % [parts[i], node.get_class()]}
		if make_unique and sub is Resource \
				and _is_external_resource(sub as Resource):
			var old_path: String = (sub as Resource).resource_path
			sub = (sub as Resource).duplicate()
			target.set(parts[i], sub)
			made_unique.append({
				"property": parts[i],
				"was": old_path,
				"now": "inline",
			})
		target = sub

	var final_prop := parts[-1]

	# --- Single colon: try slash-path override first ---
	if parts.size() == 2:
		var slash_path := parts[0] + "/" + parts[1]
		var _undo_old_slash = node.get(slash_path)

		# Try 1: node-level override via slash path.
		# Some node types (MeshInstance3D) handle slash-path _set() and
		# persist the value as a node property in .tscn.
		node.set(slash_path, coerced)
		var readback = node.get(slash_path)
		if readback != null:
			var result := _check_set_readback_value(readback, coerced, property_name)
			if not made_unique.is_empty():
				result["made_unique"] = made_unique
			if result.get("ok", false):
				var undo := {"type": "property", "path": slash_path, "old": _undo_old_slash}
				if _undo_old_resource != null and not made_unique.is_empty():
					undo["old_resource_prop"] = parts[0]
					undo["old_resource"] = _undo_old_resource
				result["_undo"] = undo
			return result

	# --- Direct sub-resource mutation ---
	# For single-colon when slash-path didn't work, and all multi-colon.
	# Persists only for inline sub-resources (.tscn [sub_resource] section).
	# External resources: in-memory only → warn.
	var _undo_old_sub = _read_sub_property(target, final_prop)
	_write_sub_property(target, final_prop, coerced)
	var readback = _read_sub_property(target, final_prop)
	var result := _check_set_readback_value(readback, coerced, property_name)
	if not made_unique.is_empty():
		result["made_unique"] = made_unique
	if result.get("ok", false):
		# Sub-resource direct mutation — undo navigates the chain via helper.
		result["_undo"] = {"type": "sub_resource", "path": property_name,
			"old": _undo_old_sub, "new": coerced}
	if result.get("ok", false) \
			and target is Resource \
			and _is_external_resource(target as Resource):
		result["warning"] = (
			"Value was set on a shared external sub-resource in memory. "
			+ "This change may not persist after save/reload. "
			+ "Retry with make_unique: true to auto-duplicate all external "
			+ "resources in the chain as inline copies.")
	return result


## Read a compound-path property from a node, handling colon-chain paths.
## Returns {"ok": true, "value": <serialized>} on success,
## {"ok": false, "code": ..., "error": ...} on failure.
##
## For single-colon paths, tries node-level override first (slash conversion),
## falls back to sub-resource read (returns resource defaults when no override).
## This matches Inspector behavior: show the effective value.
static func get_property_compound(node: Object, property_name: String) -> Dictionary:
	# No colon — read directly from node (handles slash-only compound paths).
	if ":" not in property_name:
		return {"ok": true, "value": Coerce.serialize_value(node.get(property_name))}

	var parts := property_name.split(":")

	# Single colon: try node-level override first, then sub-resource default.
	if parts.size() == 2:
		var slash_path := parts[0] + "/" + parts[1]
		var value = node.get(slash_path)
		if value != null:
			return {"ok": true, "value": Coerce.serialize_value(value)}
		# Null fallback: navigate to sub-resource and read from it.
		var sub = node.get(parts[0])
		if sub == null or not (sub is Object):
			return {"ok": false, "code": "NOT_FOUND",
				"error": "sub-resource '%s' is null on %s" % [parts[0], node.get_class()]}
		var fallback_value = _read_sub_property(sub, parts[1])
		return {"ok": true, "value": Coerce.serialize_value(fallback_value)}

	# Multi colon: manual sub-resource navigation.
	var target: Object = node
	var final_prop := parts[-1]
	for i in range(parts.size() - 1):
		var sub = target.get(parts[i])
		if sub == null or not (sub is Object):
			return {"ok": false, "code": "NOT_FOUND",
				"error": "sub-resource '%s' is null on %s" % [parts[i], node.get_class()]}
		target = sub
	var value = _read_sub_property(target, final_prop)
	return {"ok": true, "value": Coerce.serialize_value(value)}


# -- Compound path helpers (private) ------------------------------------------


## Read a property from a sub-resource, using dedicated getters where needed.
static func _read_sub_property(target: Object, prop: String) -> Variant:
	if prop.begins_with("shader_parameter/") and target is ShaderMaterial:
		return (target as ShaderMaterial).get_shader_parameter(
			prop.trim_prefix("shader_parameter/"))
	return target.get(prop)


## Write a property on a sub-resource, using dedicated setters where needed.
static func _write_sub_property(target: Object, prop: String, value: Variant) -> void:
	if prop.begins_with("shader_parameter/") and target is ShaderMaterial:
		(target as ShaderMaterial).set_shader_parameter(
			prop.trim_prefix("shader_parameter/"), value)
	else:
		target.set(prop, value)


## Check whether a Resource is stored externally (standalone .tres/.res file)
## vs inline (built-in sub-resource in a scene or parent resource).
static func _is_external_resource(res: Resource) -> bool:
	var path := res.resource_path
	if path.is_empty():
		return false
	# Inline sub-resources have paths like "res://scene.tscn::unique_id".
	if "::" in path:
		return false
	return true


## Verify a SET succeeded by reading back from the target and comparing.
## target_obj + readback_prop define WHERE to read; original_path is for errors.
static func _check_set_readback(
	target: Object, readback_prop: String, coerced: Variant, original_path: String,
) -> Dictionary:
	var readback = _read_sub_property(target, readback_prop)
	return _check_set_readback_value(readback, coerced, original_path)


## Compare a readback value against the expected coerced value.
static func _check_set_readback_value(
	readback: Variant, coerced: Variant, original_path: String,
) -> Dictionary:
	if readback == null and coerced != null:
		return {"ok": false, "code": "SET_FAILED",
			"error": "set() on '%s' reported no error but readback is null. "
			% original_path
			+ "The property may require a dedicated API (e.g. set_shader_parameter, "
			+ "add_animation_library)."}
	if typeof(readback) == typeof(coerced) and readback != coerced:
		return {"ok": false, "code": "SET_FAILED",
			"error": "set '%s' to %s but readback is %s — value did not persist. "
			% [original_path, str(coerced), str(readback)]
			+ "The property may need a dedicated API or the resource may be read-only."}
	return {"ok": true, "value": coerced}


## Check whether a property name exists on an object instance.
## Uses get_property_list() which covers built-in, @export, and metadata.
static func _has_property(obj: Object, property_name: String) -> bool:
	for p in obj.get_property_list():
		if p["name"] == property_name:
			return true
	return false


# -- Scene node resolution -----------------------------------------------------


static func get_edited_root() -> Node:
	return EditorInterface.get_edited_scene_root()


static func resolve_scene_node(node_path: String) -> Variant:
	var root := get_edited_root()
	if root == null:
		return null
	if node_path.is_empty() or node_path == ".":
		return root
	return root.get_node_or_null(node_path)


## Translate runtime-style /root/ paths to editor-relative paths.
## Agents often pass "/root/Main/Player" when they mean "./Player".
## Editor commands operate on the edited scene tree where the root
## is always "." — there is no /root node.  The first segment after
## /root/ is the runtime scene root name and is stripped.
## When the path has children ("/root/X/Child"), the scene-name segment
## is stripped unconditionally (casing may differ between runtime and
## editor).  When the path is "/root/X" alone (no children), we validate
## X against the current edited scene root name (case-insensitive) so
## that clearly non-existent paths like "/root/NoSuch" propagate as-is
## and produce NOT_FOUND from the caller's get_node_or_null.
static func normalize_editor_path(raw_path: String) -> String:
	if not raw_path.begins_with("/root/") and raw_path != "/root":
		return raw_path

	# "/root" alone → "."
	if raw_path == "/root":
		return "."

	# Strip "/root/" prefix — remainder is "SceneName" or "SceneName/Child/..."
	var after_root := raw_path.substr(6)  # len("/root/") == 6

	var slash_idx := after_root.find("/")
	if slash_idx < 0:
		# "/root/SceneName" (no further children) — validate against the
		# current edited scene root.  If the name doesn't match, the path
		# refers to a non-existent node; return raw_path so the caller's
		# get_node_or_null produces NOT_FOUND.
		var edited_root := EditorInterface.get_edited_scene_root()
		if edited_root != null and after_root.to_lower() != edited_root.name.to_lower():
			return raw_path
		return "."

	# "/root/SceneName/Child/..." → "./Child/..."
	return "." + after_root.substr(slash_idx)


# -- Class hierarchy checks ----------------------------------------------------


static func class_descends_from(type_name: String, base: String) -> bool:
	if ClassDB.class_exists(type_name):
		return ClassDB.is_parent_class(type_name, base)
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return class_descends_from(str(entry.get("base", "")), base)
	return false


static func class_base_chain(type_name: String) -> String:
	var chain := PackedStringArray()
	var current := type_name
	var depth := 0
	while not current.is_empty() and depth < 16:
		chain.append(current)
		if ClassDB.class_exists(current):
			var parent := ClassDB.get_parent_class(current)
			if parent.is_empty():
				break
			current = parent
		else:
			var found := false
			for entry in ProjectSettings.get_global_class_list():
				if str(entry.get("class", "")) == current:
					current = str(entry.get("base", ""))
					found = true
					break
			if not found:
				break
		depth += 1
	return " -> ".join(chain)


# -- Scene tab management ------------------------------------------------------


## Open a scene in the editor using call_deferred to avoid deferred-queue
## collisions (godotengine/godot#75669). Yields one frame so the editor
## fully settles before the next MCP command executes.
static func open_scene_deferred(file_path: String) -> void:
	EditorInterface.open_scene_from_path.call_deferred(file_path)
	await (Engine.get_main_loop() as SceneTree).process_frame


## Attempt to close the editor tab for `file_path`.
## Returns {closed: true} or {closed: false, reason: String}.
##
## Reason codes:
##   "not_open" — file has no open editor tab
##   "no_api"   — Godot 4.2–4.4 (no close_scene method)
##
## On 4.5+ the engine auto-creates an empty scene if the last tab is closed,
## so there is no "last_tab" guard — the caller never needs to worry about it.
##
## SAFETY: performs at most ONE open_scene_from_path + close_scene cycle.
## Never loops. Uses call_deferred for both open and close to avoid
## deferred-queue collisions (godotengine/godot#75669). Yields a frame
## after each deferred call so the editor fully settles before the
## next MCP command can execute.
##
## NOTE: does NOT restore the previously-active tab. After closing a
## non-active tab, Godot auto-switches to an adjacent tab. Restoring
## via a third open_scene_from_path triggers a benign but noisy
## _set_main_scene_state deferred-queue error in the engine — not
## worth the console spam.
static func close_scene_tab_safe(file_path: String) -> Dictionary:
	var open_scenes := EditorInterface.get_open_scenes()
	if not open_scenes.has(file_path):
		return {"closed": false, "reason": "not_open"}

	# Version gate: close_scene() requires 4.5+.
	if not EditorInterface.has_method("close_scene"):
		return {"closed": false, "reason": "no_api"}

	var tree := Engine.get_main_loop() as SceneTree

	# If the target is not the active tab, activate it first.
	# Use call_deferred to avoid deferred-queue collisions
	# (godotengine/godot#75669 — direct calls from plugin code can crash).
	var current_root := get_edited_root()
	var current_path := current_root.scene_file_path if current_root else ""
	var switched := (current_path != file_path)
	if switched:
		await open_scene_deferred(file_path)

	# Close the now-active tab via call_deferred for the same reason.
	EditorInterface.call_deferred("close_scene")
	await tree.process_frame

	return {"closed": true, "switched": switched}


# -- File operations -----------------------------------------------------------


## Delete a res:// file and its companion files (.uid, .import).
## Clears the in-memory ResourceUID cache to prevent stale-UID errors.
## Returns {success: true, path: String} or an McpError dict.
static func delete_res_file(file_path: String, companions: Array = [".uid"]) -> Dictionary:
	# Capture the UID before deleting so we can evict it from the cache.
	var uid: int = ResourceLoader.get_resource_uid(file_path)

	var directory := DirAccess.open("res://")
	if directory == null:
		return McpError.make("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return McpError.make("DELETE_FAILED",
			"DirAccess.remove returned %d (path=%s)" % [remove_error, file_path])
	for suffix in companions:
		var companion_relative: String = relative_path + str(suffix)
		if directory.file_exists(companion_relative):
			directory.remove(companion_relative)

	# Evict the UID from the in-memory singleton so the engine doesn't
	# reference a now-deleted path. On clean shutdown the cache file
	# (uid_cache.bin) is rewritten without the removed entry.
	if uid != -1 and ResourceUID.has_id(uid):
		ResourceUID.remove_id(uid)

	return {"success": true, "path": file_path}


## Ensure parent directory exists, auto-creating if needed.
## Returns {ok: true, dirs_created: bool} or an McpError dict on failure.
static func ensure_parent_dir(file_path: String, context: String = "") -> Dictionary:
	var parent_dir := file_path.get_base_dir()
	if DirAccess.dir_exists_absolute(parent_dir):
		return {"ok": true, "dirs_created": false}
	var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
	if mkdir_err != OK:
		return McpError.make("PARENT_NOT_FOUND",
			"parent directory %s does not exist and auto-create failed (err %d); call folder.create manually" % [parent_dir, mkdir_err])
	if not context.is_empty():
		push_warning("[MCPTools] auto-created directory %s for %s" % [parent_dir, context])
	return {"ok": true, "dirs_created": true}


# -- EditorFileSystem targeted updates ----------------------------------------


## Targeted index: call update_file() and poll until indexed or timeout.
## Falls back to scan() if update_file() alone does not index the file
## (e.g. the parent directory is new and not yet in EditorFileSystem).
## Returns {indexed: bool, file_class: String, elapsed_ms: int}.
static func ensure_file_indexed(file_path: String, timeout_ms: int = 3000) -> Dictionary:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return {"indexed": false, "file_class": "", "elapsed_ms": 0}
	filesystem.update_file(file_path)
	var elapsed := 0
	while filesystem.get_file_type(file_path) == "" and elapsed < timeout_ms:
		OS.delay_msec(100)
		elapsed += 100
	if filesystem.get_file_type(file_path) != "":
		var file_class := filesystem.get_file_type(file_path)
		return {"indexed": true, "file_class": file_class, "elapsed_ms": elapsed}
	# Fallback: update_file() could not index — parent dir may be unknown. Full scan.
	filesystem.scan()
	while filesystem.is_scanning() and elapsed < timeout_ms:
		OS.delay_msec(100)
		elapsed += 100
	var file_class := filesystem.get_file_type(file_path)
	var result := {"indexed": file_class != "", "file_class": file_class, "elapsed_ms": elapsed}
	if not result["indexed"]:
		result["hint"] = "indexed is advisory — script_check, resource_load, and scene_open work regardless. Call editor_refresh only if asset_list visibility is needed."
	return result


## Targeted deindex: call update_file() on a deleted path and poll until
## removed from the index. Falls back to scan() if update_file() alone
## does not clear the entry (directory-level or engine quirk).
## Returns {removed: bool, elapsed_ms: int}.
static func ensure_file_removed(file_path: String, timeout_ms: int = 3000) -> Dictionary:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return {"removed": false, "elapsed_ms": 0}
	filesystem.update_file(file_path)
	var elapsed := 0
	while filesystem.get_file_type(file_path) != "" and elapsed < timeout_ms:
		OS.delay_msec(100)
		elapsed += 100
	if filesystem.get_file_type(file_path) == "":
		return {"removed": true, "elapsed_ms": elapsed}
	# Fallback: update_file() did not remove the entry — full scan.
	filesystem.scan()
	while filesystem.is_scanning() and elapsed < timeout_ms:
		OS.delay_msec(100)
		elapsed += 100
	var removed := filesystem.get_file_type(file_path) == ""
	return {"removed": removed, "elapsed_ms": elapsed}


# -- ANSI stripping ------------------------------------------------------------


## Compiled once at script load — one allocation per editor session.
## CSI sequences: ESC [ <params> <final>  (e.g. ESC[90m, ESC[0m)
## Simple escapes: ESC <letter>            (e.g. ESC c)
static var _ansi_re: RegEx = _compile_ansi_re()

static func _compile_ansi_re() -> RegEx:
	var re := RegEx.new()
	re.compile("\\x1b(?:\\[[0-9;]*[A-Za-z]|[A-Za-z])")
	return re


## Strip ANSI/VT100 escape sequences from a string.
## In headless mode Godot emits ANSI color codes in progress-bar and
## status messages. These contain raw ESC (0x1B) bytes that Godot's
## JSON.stringify() does not escape, producing invalid JSON and causing
## the TypeScript bridge to silently drop responses.
static func strip_ansi(text: String) -> String:
	return _ansi_re.sub(text, "", true)


# -- Log level detection -------------------------------------------------------


static func detect_log_level(line: String) -> String:
	if line.begins_with("ERROR:") or line.begins_with("USER ERROR:") \
			or line.begins_with("SCRIPT ERROR:"):
		return "error"
	if line.begins_with("WARNING:") or line.begins_with("USER WARNING:") \
			or line.begins_with("SCRIPT WARNING:"):
		return "warning"
	return "info"


# -- Profile conversion --------------------------------------------------------


static func profile_to_string(profile: int) -> String:
	match profile:
		0: return "minimal"
		1: return "standard"
		2: return "power_user"
		_: return "standard"


static func string_to_profile(s: String) -> int:
	match s.to_lower():
		"minimal": return 0
		"standard": return 1
		"power_user", "full": return 2
		_: return 1


# -- File logging detection ----------------------------------------------------


## Check whether file logging is enabled, including platform-specific overrides.
## ProjectSettings.get_setting() returns the base value; platform overrides
## (e.g. debug/file_logging/enable_file_logging.windows) are separate keys.
static func is_file_logging_enabled() -> bool:
	var key := "debug/file_logging/enable_file_logging"
	if ProjectSettings.get_setting(key, false):
		return true
	for tag in ["pc", "windows", "linuxbsd", "macos", "android", "ios", "web"]:
		if OS.has_feature(tag):
			var override_key: String = key + "." + tag
			if ProjectSettings.has_setting(override_key) \
					and ProjectSettings.get_setting(override_key, false):
				return true
	return false
