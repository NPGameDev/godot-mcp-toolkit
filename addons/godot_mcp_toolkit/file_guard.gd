@tool
extends RefCounted
## Filesystem boundary enforcement (I4).
##
## Every command that touches the filesystem calls resolve_safe() to
## validate and canonicalize the path before any I/O. Default allows
## res:// only; callers opt in to additional prefixes (e.g.
## user://screenshots/) via the allowed_prefixes parameter.
##
## resolve_safe_user() (iter 19c) extends access to whitelisted user://
## subpaths behind the read_user_scope FeatureGate + a plugin-author-
## configured whitelist at addons/godot_mcp_toolkit/user_scope_whitelist.json.

const MCPFeatureGate := preload("res://addons/godot_mcp_toolkit/feature_gate.gd")

const _WHITELIST_PATH := "res://addons/godot_mcp_toolkit/user_scope_whitelist.json"

static var _user_whitelist: Variant = null  # null = not loaded; Dictionary = cached


static func reload_user_whitelist() -> void:
	_user_whitelist = null


static func _load_user_whitelist() -> Variant:
	if _user_whitelist != null:
		return _user_whitelist
	if not FileAccess.file_exists(_WHITELIST_PATH):
		return null
	var f := FileAccess.open(_WHITELIST_PATH, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	# Validate entries — reject blanket-match or traversal entries.
	for mode in ["read", "write", "delete"]:
		var entries = parsed.get(mode, [])
		if typeof(entries) != TYPE_ARRAY:
			parsed[mode] = []
			continue
		var clean: Array = []
		for entry in entries:
			var s := str(entry)
			if s == "" or s == "/" or s.find("..") != -1:
				push_warning("MCP: whitelist entry '%s' in '%s' rejected — too broad or contains .." % [s, mode])
				continue
			clean.append(s)
		parsed[mode] = clean
	_user_whitelist = parsed
	return _user_whitelist


## Validate and resolve a user:// path against the whitelist and FeatureGate.
## mode must be "read", "write", or "delete".
## Returns { ok: true, absolute_path } on success,
## { ok: false, error_code, error_message } on failure.
static func resolve_safe_user(path: String, mode: String) -> Dictionary:
	# Gate check.
	if not MCPFeatureGate.is_enabled("read_user_scope"):
		return {
			"ok": false,
			"error_code": "USER_SCOPE_DISABLED",
			"error_message": "user:// access is disabled; enable via env GODOT_MCP_ALLOW_USER_SCOPE=1 AND Project Settings mcp/unsafe/allow_user_scope=true",
		}
	# Reject .. segments — directory traversal.
	for segment in path.replace("\\", "/").split("/"):
		if segment == "..":
			return {
				"ok": false,
				"error_code": "USER_PATH_NOT_WHITELISTED",
				"error_message": "path contains '..': %s" % path,
			}
	# Prefix check.
	if not path.begins_with("user://"):
		return {
			"ok": false,
			"error_code": "USER_PATH_NOT_WHITELISTED",
			"error_message": "path must start with user:// (got %s); res:// paths use the res:// tool family (scene.*, script.*, resource.*, folder.*)" % path,
		}
	# Load whitelist.
	var wl = _load_user_whitelist()
	if wl == null:
		return {
			"ok": false,
			"error_code": "USER_SCOPE_DISABLED",
			"error_message": "user_scope_whitelist.json missing or malformed at addons/godot_mcp_toolkit/; plugin author must create it before user:// tools are usable",
		}
	# Mode entries.
	var entries: Array = wl.get(mode, [])
	if entries.is_empty():
		return {
			"ok": false,
			"error_code": "USER_PATH_NOT_WHITELISTED",
			"error_message": "no user:// paths are whitelisted for %s (whitelist is configured by the plugin author in addons/godot_mcp_toolkit/user_scope_whitelist.json)" % mode,
		}
	# Match against whitelist.
	var rel := path.trim_prefix("user://")
	var matched := false
	for entry in entries:
		var e := str(entry)
		if e.ends_with("/"):
			if rel.begins_with(e):
				matched = true
				break
		else:
			if rel == e:
				matched = true
				break
	if not matched:
		return {
			"ok": false,
			"error_code": "USER_PATH_NOT_WHITELISTED",
			"error_message": "path %s not in %s whitelist; whitelisted entries for this mode: [%s]" % [path, mode, ", ".join(entries)],
		}
	# Normalize + escape guard.
	var abs_path := ProjectSettings.globalize_path(path)
	var user_root := ProjectSettings.globalize_path("user://").simplify_path()
	if not abs_path.simplify_path().begins_with(user_root):
		return {
			"ok": false,
			"error_code": "USER_PATH_NOT_WHITELISTED",
			"error_message": "path %s resolves outside user data dir (possible symlink escape)" % path,
		}
	return {"ok": true, "absolute_path": abs_path}


static func resolve_safe(
	input: String, allowed_prefixes: Array = ["res://"],
) -> Dictionary:
	if input.strip_edges().is_empty():
		return _denied("empty path")

	var normalized := input.replace("\\", "/")

	# Reject ".." path segments — directory traversal.
	for segment in normalized.split("/"):
		if segment == "..":
			return _denied("path contains '..': %s" % input)

	# Reject absolute OS paths (drive letters, UNC, Unix root).
	if normalized.length() >= 2 and normalized[1] == ":":
		return _denied("absolute OS path: %s" % input)
	if normalized.begins_with("/") \
			and not normalized.begins_with("res://") \
			and not normalized.begins_with("user://"):
		return _denied("absolute OS path: %s" % input)
	if normalized.begins_with("\\\\"):
		return _denied("absolute OS path (UNC): %s" % input)

	# Prefix allowlist.
	var matched := false
	for prefix in allowed_prefixes:
		if normalized.begins_with(str(prefix)):
			matched = true
			break
	if not matched:
		var allowed_str := ", ".join(
			allowed_prefixes.map(func(p: Variant) -> String: return str(p)))
		return _denied(
			"path must start with one of [%s] (got %s)" % [allowed_str, input])

	# Canonicalize: globalize -> simplify -> verify still under boundary.
	var globalized := ProjectSettings.globalize_path(input)
	var simplified := globalized.simplify_path()

	if normalized.begins_with("user://"):
		var user_root := ProjectSettings.globalize_path("user://").simplify_path()
		if not simplified.begins_with(user_root):
			return _denied("path escapes user:// boundary: %s" % input)
	else:
		var project_root := ProjectSettings.globalize_path("res://").simplify_path()
		if not simplified.begins_with(project_root):
			return _denied("path escapes project boundary: %s" % input)

	return {"path": input, "error": null}


static func _denied(reason: String) -> Dictionary:
	return {"path": "", "error": "PATH_DENIED", "reason": reason}
