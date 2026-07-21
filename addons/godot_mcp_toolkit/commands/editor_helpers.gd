@tool
extends RefCounted
## Shared helpers used across multiple command handlers.
## Eliminates duplication of scene-node resolution, class hierarchy
## checks, file deletion, directory creation, and log-level detection.

## NOTE: This file is preloaded by core/modules.gd, so it CANNOT import core/modules.gd
## (circular dependency). Use direct preloads for dependencies instead.
const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const PropertySetCheck := preload("res://addons/godot_mcp_toolkit/contract/property_set_check.gd")


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
		var err := MCPToolkitError.fail("INVALID_PARAMS",
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
		var result := _check_set_readback(node, property_name, _undo_old, coerced, property_name)
		if result.get("ok", false):
			result["_undo"] = {"type": "property", "path": property_name, "old": _undo_old}
		else:
			# Dropped: a bound setter (position/modulate) may have zeroed the value;
			# restore the prior value so the failure is non-destructive.
			node.set(property_name, _undo_old)
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
			var result := _check_set_readback_value(_undo_old_slash, readback, coerced, property_name)
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
	var result := _check_set_readback_value(_undo_old_sub, readback, coerced, property_name)
	if not made_unique.is_empty():
		result["made_unique"] = made_unique
	if result.get("ok", false):
		# Sub-resource direct mutation — undo navigates the chain via helper.
		var undo := {"type": "sub_resource", "path": property_name,
			"old": _undo_old_sub, "new": coerced}
		if _undo_old_resource != null and not made_unique.is_empty():
			undo["old_resource_prop"] = parts[0]
			undo["old_resource"] = _undo_old_resource
		result["_undo"] = undo
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
## target + readback_prop define WHERE to read the post-set value; before is the
## pre-set value (the property's type oracle); original_path is for errors.
static func _check_set_readback(
	target: Object, readback_prop: String, before: Variant,
	coerced: Variant, original_path: String,
) -> Dictionary:
	var after = _read_sub_property(target, readback_prop)
	return _check_set_readback_value(before, after, coerced, original_path)


## Map the [method describe_set_drop] tri-state onto the {ok:…} result shape the
## compound-path callers expect. A clean write keeps the historical
## {"ok": true, "value": coerced}; an ADJUSTED write adds a "warning" (the compound
## callers already propagate result["warning"]); a DROPPED write is SET_FAILED.
static func _check_set_readback_value(
	before: Variant, after: Variant, coerced: Variant, original_path: String,
) -> Dictionary:
	var outcome := describe_set_drop(before, after, coerced, original_path)
	match str(outcome.get("status", "")):
		"dropped":
			return {"ok": false, "code": "SET_FAILED", "error": str(outcome.get("error", ""))}
		"adjusted":
			return {"ok": true, "value": coerced, "warning": str(outcome.get("warning", ""))}
		_:
			return {"ok": true, "value": coerced}


## Property-set-outcome classifier — delegates to the runtime-safe pure leaf
## [code]contract/property_set_check.gd[/code] (the SSOT shared with the runtime
## autoload's [code]runtime.set_property[/code]). Kept here as
## [code]Helpers.describe_set_drop[/code] so the editor node/scene property-set
## paths reach it through their existing helper facade with no call-site churn.
## Returns the tri-state {"status": "ok" | "adjusted" (+warning) | "dropped" (+error)}.
static func describe_set_drop(
	before: Variant, after: Variant, coerced: Variant, path: String,
) -> Dictionary:
	return PropertySetCheck.describe_set_drop(before, after, coerced, path)


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


## Resolve a class name to its kind. Returns {"kind": "native"|"global"|"",
## "entry": Dictionary} -- "entry" is the global-class-list row for a global
## class, {} otherwise. Caller owns the unknown-class error + the descends-from check.
static func resolve_class_kind(type_name: String) -> Dictionary:
	if ClassDB.class_exists(type_name):
		return {"kind": "native", "entry": {}}
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == type_name:
			return {"kind": "global", "entry": entry}
	return {"kind": "", "entry": {}}


# -- Scene tab management ------------------------------------------------------


## Open a scene in the editor using call_deferred to avoid deferred-queue
## collisions (godotengine/godot#75669). Yields one frame so the editor
## fully settles before the next MCP command executes.
static func open_scene_deferred(file_path: String) -> bool:
	# Never open into an active EditorFileSystem scan (the load reads
	# inconsistent state and can crash). Returns false on scan-idle timeout so
	# callers can abort rather than collide with the scan.
	if not await MCPToolkitSafeSceneOps.wait_for_scan_idle():
		return false
	EditorInterface.open_scene_from_path.call_deferred(file_path)
	await (Engine.get_main_loop() as SceneTree).process_frame
	return true


## Attempt to close the editor tab for `file_path`.
## Returns {closed: true, switched: bool} or {closed: false, reason: String}.
##
## On success, [code]unsaved_changes_discarded: bool[/code] is included only on
## Godot 4.7+ (where a dirty query is bound); it reports whether the closed tab
## had unsaved edits that closing threw away. The key is absent on 4.5/4.6 —
## absence means "not determinable", distinct from a detected-clean [code]false[/code].
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

	# Best-effort dirty disclosure: capture whether the tab has unsaved edits
	# BEFORE the switch/close mutate editor state, so the caller can warn that
	# closing discards them. get_unsaved_scenes() is only bound in Godot 4.7;
	# older editors expose no dirty query, so this stays absent below 4.7 and
	# the field is simply omitted rather than reported as a false "clean".
	var disclose_unsaved := EditorInterface.has_method("get_unsaved_scenes")
	var unsaved_discarded := false
	if disclose_unsaved:
		# Call via has_method + call: the method is unbound below 4.7, so a direct
		# static reference would parse-fail on older editors.
		var unsaved: PackedStringArray = EditorInterface.call("get_unsaved_scenes")
		unsaved_discarded = file_path in unsaved

	# If the target is not the active tab, activate it first.
	# Use call_deferred to avoid deferred-queue collisions
	# (godotengine/godot#75669 — direct calls from plugin code can crash).
	var current_root := get_edited_root()
	var current_path := current_root.scene_file_path if current_root else ""
	var switched := (current_path != file_path)
	if switched:
		if not await open_scene_deferred(file_path):
			return {"closed": false, "reason": "scan_timeout"}

	# Close the now-active tab via call_deferred for the same reason.
	EditorInterface.call_deferred("close_scene")
	await tree.process_frame

	var result := {"closed": true, "switched": switched}
	# Only surface the field where it is actually detectable (4.7+); absence
	# signals "not determinable here", distinct from a detected clean tab.
	if disclose_unsaved:
		result["unsaved_changes_discarded"] = unsaved_discarded
	return result


# -- File operations -----------------------------------------------------------


## Delete a res:// file and its companion files (.uid, .import).
## Clears the in-memory ResourceUID cache to prevent stale-UID errors.
## Returns {success: true, path: String} or an MCPToolkitError dict.
static func delete_res_file(file_path: String, companions: Array = [".uid"]) -> Dictionary:
	# Capture the UID before deleting so we can evict it from the cache.
	var uid: int = ResourceLoader.get_resource_uid(file_path)

	var directory := DirAccess.open("res://")
	if directory == null:
		return MCPToolkitError.fail("INTERNAL", "DirAccess.open(res://) returned null")
	var relative_path := file_path.substr("res://".length())
	var remove_error := directory.remove(relative_path)
	if remove_error != OK:
		return MCPToolkitError.fail("DELETE_FAILED",
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
## Returns {ok: true, dirs_created: bool} or an MCPToolkitError dict on failure.
static func ensure_parent_dir(file_path: String, context: String = "") -> Dictionary:
	var parent_dir := file_path.get_base_dir()
	if DirAccess.dir_exists_absolute(parent_dir):
		return {"ok": true, "dirs_created": false}
	var mkdir_err := DirAccess.make_dir_recursive_absolute(parent_dir)
	if mkdir_err != OK:
		return MCPToolkitError.fail("PARENT_NOT_FOUND",
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
	var start := Time.get_ticks_msec()
	while filesystem.get_file_type(file_path) == "" and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	if filesystem.get_file_type(file_path) != "":
		var file_class := filesystem.get_file_type(file_path)
		return {"indexed": true, "file_class": file_class, "elapsed_ms": Time.get_ticks_msec() - start}
	# Fallback: update_file() could not index — parent dir may be unknown. Full scan.
	filesystem.scan()
	while filesystem.is_scanning() and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	var elapsed := Time.get_ticks_msec() - start
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
	var start := Time.get_ticks_msec()
	while filesystem.get_file_type(file_path) != "" and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	if filesystem.get_file_type(file_path) == "":
		return {"removed": true, "elapsed_ms": Time.get_ticks_msec() - start}
	# Fallback: update_file() did not remove the entry — full scan.
	filesystem.scan()
	while filesystem.is_scanning() and Time.get_ticks_msec() - start < timeout_ms:
		await Engine.get_main_loop().create_timer(0.1).timeout
	var elapsed := Time.get_ticks_msec() - start
	var removed := filesystem.get_file_type(file_path) == ""
	return {"removed": removed, "elapsed_ms": elapsed}


## Delete a res:// file (+companions) then targeted-deindex it. Returns the
## delete_res_file dict with "deindexed": bool merged in on success; on failure
## the dict is the unmodified delete_res_file error (no "deindexed" key). Folds
## the delete -> ensure_file_removed -> deindexed sequence shared by file/scene/
## resource/script delete so each caller no longer repeats the success-guard +
## key write. delete_res_file is not a coroutine (not awaited); only the
## ensure_file_removed poll yields.
static func delete_res_file_and_deindex(
	file_path: String, companions: Array = [".uid"],
) -> Dictionary:
	var delete_result: Dictionary = delete_res_file(file_path, companions)
	if delete_result.get("success", false):
		var removal: Dictionary = await ensure_file_removed(file_path)
		delete_result["deindexed"] = removal["removed"]
	return delete_result


# -- Godot 4.3 SceneTreeEditor tooltip-timer UAF mitigation -------------------


## True on Godot 4.3.x — the only engine line that needs the tooltip-timer disarm.
## 4.2 renders node tooltips synchronously (no deferred timer to strand); 4.4+ caches
## TreeItems across tree rebuilds (PR #99700) so the bound row outlives the churn.
## Pure (engine_ver injected, e.g. VersionUtils.get_engine_version_pair()) so the
## exact 4.3-only boundary is headless-unit-tested. The disarm is zero-cost, so the
## gate is version-only — no OS axis.
static func should_disarm_tooltip_uaf(engine_ver: String) -> bool:
	return engine_ver == "4.3"


## Before a toolkit write of [param node]'s [param property], drop Godot 4.3's
## SceneTreeEditor tooltip-timer connections so the write cannot arm a use-after-free.
## No-op unless [param property] is [code]editor_description[/code] and the engine is
## 4.3.x (see [method should_disarm_tooltip_uaf]).
## [br]
## On 4.3, setting [code]editor_description[/code] emits
## [code]editor_description_changed[/code]; each connected SceneTreeEditor arms a 0.5s
## one-shot Timer bound to the node's current [code]TreeItem*[/code], and concurrent
## tree churn then runs [code]tree->clear()[/code] (no TreeItem cache before 4.4),
## freeing that row — so the timer fires on freed memory → editor SIGSEGV. Removing the
## SceneTreeEditor slots before the set means nothing arms. No reconnect is needed: the
## editor re-adds the connection with a fresh row bind and refreshes the tooltip
## synchronously on its next tree rebuild (scene_tree_editor.cpp:371-376), so no tooltip
## is lost. Only SceneTreeEditor slots are removed — a user script connected to the same
## public signal is left intact.
## [br]
## Call this immediately before the set with no [code]await[/code] in between; a yield
## would let tree churn re-add and re-arm a slot. A later human undo/redo replays the set
## outside this guard, exposing it exactly like any inspector edit — out of scope here
## (cured upstream in 4.4). Any new tool or extension that writes editor_description MUST
## call this (see docs/extending.md).
static func disarm_tooltip_uaf(node: Object, property: String) -> void:
	if property != "editor_description":
		return
	if not should_disarm_tooltip_uaf(VersionUtils.get_engine_version_pair()):
		return
	for conn in node.get_signal_connection_list(&"editor_description_changed"):
		var callable: Callable = conn["callable"]
		var target: Object = callable.get_object()
		if target != null and target.get_class() == "SceneTreeEditor":
			node.disconnect(&"editor_description_changed", callable)


# -- File-create collision decision -------------------------------------------


## Resolve the file-level idempotency collision decision shared by file creators
## (scene.create, asset.import, texture/sound.generate). Pure query: validates
## if_exists, checks destination existence, and returns the DECISION only — the
## caller owns its own early-return payload, its own write, and its own status
## string (`"replaced" if existed else "created"`). Centralising the *decision*
## (not the payloads) keeps each creator's emitted bytes — which legitimately
## differ (extra keys, replace side-effects, message wording) — under the
## caller's control while killing the duplicated validate->exists->branch logic.
## (Pure query — this returns data, changes nothing.)
##
##   dest_path   res:// destination (NOT path-guarded here — callers guard first)
##   if_exists   "return" | "fail" | "replace"
##
## Returns a DECISION dict:
##   {valid: false}                                — if_exists was not a legal value;
##                                                   caller emits its own INVALID_PARAMS.
##   {valid: true, existed: false, action: "create"}
##                                                 — no collision; caller writes, "created".
##   {valid: true, existed: true,  action: "return"}
##                                                 — idempotent no-op; caller emits its own
##                                                   "returned" success payload.
##   {valid: true, existed: true,  action: "fail"} — caller emits its own ALREADY_EXISTS error.
##   {valid: true, existed: true,  action: "replace"}
##                                                 — caller runs its own replace side-effects
##                                                   + write, status "replaced".
static func resolve_create_collision(dest_path: String, if_exists: String) -> Dictionary:
	if if_exists not in ["return", "fail", "replace"]:
		return {"valid": false}
	var existed := FileAccess.file_exists(dest_path)
	if not existed:
		return {"valid": true, "existed": false, "action": "create"}
	# Collision: the legal if_exists value IS the action verb for this case.
	return {"valid": true, "existed": true, "action": if_exists}


# -- Batch partial-failure summary --------------------------------------------


## Roll a per-entry results[] up into a top-level partial-failure summary so a
## caller (or LLM) that reads only the top of the response still sees that some
## entries failed, instead of having to inspect every entry.
##
## Mutates and returns the SAME `response` dict: when >=1 entry failed it ADDS
## `failed` (int count) + `hint` (String); when every entry succeeded it returns
## `response` UNCHANGED (no keys added) — so an all-success batch is byte-identical
## to before. Every pre-existing key (results, count, action, warning, …) is left
## exactly as the caller set it; this only ever ADDS the two summary keys.
##
## The failure predicate is shape-tolerant so one helper serves both batch
## conventions in use: an entry is a failure iff it is a Dictionary AND
## (success == false) OR (it has no `success` key but has an `error` key). That
## covers the {success: bool} shape (node.set_property batch) and the
## {status?, error?} shape with no success field (node.groups batch).
##
## Pure (no engine state) → a headless unit test pins it with hand-built dicts.
## (Shared response shaper, beside the other pure response/decision helpers here.)
static func summarize_batch(response: Dictionary, results_key := "results") -> Dictionary:
	var entries: Array = response.get(results_key, [])
	var total := entries.size()
	var failed := 0
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var e := entry as Dictionary
		if e.get("success") == false or (not e.has("success") and e.has("error")):
			failed += 1
	if failed > 0:
		response["failed"] = failed
		response["hint"] = "%d of %d entries failed — inspect results[] for per-entry .error." % [failed, total]
	return response


# -- Shared asset write + import-settle bracket -------------------------------


## Write a generated/imported asset to a res:// path with the standard contract
## shared by asset.import, texture.generate, and sound.generate: path guard ->
## extension allowlist -> if_exists -> parent dir -> write -> import settle ->
## status/payload. The actual write is delegated to `write_fn` so each tool
## supplies only its own save call (raw bytes / Image.save_png / save_to_wav).
##
##   dest_path        res:// destination (path-guarded here)
##   allowed_exts     lowercase extensions this tool may write (e.g. ["png"])
##   if_exists        "return" (idempotent no-op) | "fail" | "replace"
##   wait_for_scan_ms import-settle timeout, [0, 30000] (0 disables the wait)
##   method           handler name, for error/dir context
##   write_fn         Callable(dest_path: String) -> Dictionary
##                    {} on success, or an MCPToolkitError.fail(...) dict on failure.
##   known_class      OPTIONAL. When non-empty, the caller GUARANTEES the saved
##                    asset's class (e.g. a generator that wrote a PNG knows it is
##                    a Texture2D). The class is then reported directly and the
##                    blocking import-settle poll is skipped (a single
##                    non-blocking update_file() still runs so the FS dock catches
##                    up). asset.import passes "" because the imported type is
##                    unknown until the editor runs the import.
##
## Returns the core success payload
## {status, path, class, warnings, elapsed_ms, success:true} (status is
## "created" | "replaced" | "returned"), or an MCPToolkitError dict
## (PATH_DENIED / INVALID_PATH / INVALID_PARAMS / ALREADY_EXISTS / PARENT_NOT_FOUND /
## WRITE_FAILED). Callers merge tool-specific fields into the returned dict on
## success (result.success == true).
static func write_asset_with_settle(
	dest_path: String,
	allowed_exts: PackedStringArray,
	if_exists: String,
	wait_for_scan_ms: int,
	method: String,
	write_fn: Callable,
	known_class: String = "",
) -> Dictionary:
	var guard := FileGuard.resolve_safe(dest_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))

	var extension := dest_path.get_extension().to_lower()
	if not allowed_exts.has(extension):
		return MCPToolkitError.fail("INVALID_PATH",
			"extension '%s' not allowed for %s; expected: %s" % [
				extension, method, ", ".join(allowed_exts)])

	var collision := resolve_create_collision(dest_path, if_exists)
	if not collision["valid"]:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"if_exists must be one of 'return', 'fail', 'replace' (got '%s')" % if_exists)
	if wait_for_scan_ms < 0 or wait_for_scan_ms > 30000:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"wait_for_scan_ms must be in [0, 30000] (got %d); 0 disables wait" % wait_for_scan_ms)

	var file_existed: bool = collision["existed"]
	if file_existed:
		match collision["action"]:
			"return":
				return MCPToolkitSuccess.ok({
					"status": "returned", "path": dest_path,
					"class": known_class if known_class != "" else _file_class_or_null(dest_path), "warnings": [], "elapsed_ms": 0})
			"fail":
				return MCPToolkitError.fail("ALREADY_EXISTS",
					"file already exists at %s; use if_exists:'replace' to overwrite or if_exists:'return' for idempotent no-op" % dest_path)
			"replace":
				pass

	var dir_result := ensure_parent_dir(dest_path, method)
	if dir_result.has("error"):
		return dir_result

	var write_result: Variant = write_fn.call(dest_path)
	if typeof(write_result) == TYPE_DICTIONARY and (write_result as Dictionary).has("error"):
		return write_result

	var warnings: Array[String] = []
	var file_class: Variant = null
	var elapsed_ms := 0

	if known_class != "" and wait_for_scan_ms <= 0:
		# Generator default path: the class is known by construction, so skip the
		# blocking import-settle poll entirely. Fire one non-blocking update_file()
		# so the FS dock catches up; the asset is usable regardless (resource_load
		# imports on demand). No "did not index" warning — we never waited.
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.update_file(dest_path)
		file_class = known_class
	else:
		# asset.import (type unknown until the editor imports → must settle via the
		# FS), OR a generator that explicitly opted into a wait (wait_for_scan_ms > 0).
		var index_result := await ensure_file_indexed(dest_path, wait_for_scan_ms)
		elapsed_ms = int(index_result["elapsed_ms"])
		if not index_result["indexed"]:
			warnings.append(
				"EditorFileSystem did not index %s within %dms — call editor.wait_for_idle to finish" % [dest_path, wait_for_scan_ms])
		if known_class != "":
			file_class = known_class  # generator: the constructed class is authoritative
		elif str(index_result["file_class"]) != "":
			file_class = index_result["file_class"]

	var status := "replaced" if file_existed else "created"
	return MCPToolkitSuccess.ok({
		"status": status,
		"path": dest_path,
		"class": file_class,
		"warnings": warnings,
		"elapsed_ms": elapsed_ms,
	})


## EditorFileSystem class name for an already-indexed file, or null if unknown.
static func _file_class_or_null(file_path: String) -> Variant:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem == null:
		return null
	var file_type := filesystem.get_file_type(file_path)
	return file_type if file_type != "" else null
