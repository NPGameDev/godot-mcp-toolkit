@tool
extends RefCounted
## Filesystem boundary enforcement.
##
## Every command that touches the filesystem calls resolve_safe() to
## validate and canonicalize the path before any I/O. Default allows
## res:// only; callers opt in to additional prefixes (e.g.
## user://screenshots/) via the allowed_prefixes parameter.
##
## resolve_safe_user() validates user:// paths: rejects traversal
## and symlink escapes, then returns the globalized absolute path.


## Validate and resolve a user:// path.
## Returns { ok: true, absolute_path } on success,
## { ok: false, error_code, error_message } on failure.
static func resolve_safe_user(path: String) -> Dictionary:
	# Reject .. segments — directory traversal.
	for segment in path.replace("\\", "/").split("/"):
		if segment == "..":
			return {
				"ok": false,
				"error_code": "INVALID_PATH",
				"error_message": "path contains '..': %s" % path,
			}
	# Prefix check.
	if not path.begins_with("user://"):
		return {
			"ok": false,
			"error_code": "INVALID_PATH",
			"error_message": "path must start with user:// (got %s); res:// paths use the res:// tool family (scene.*, script.*, resource.*, folder.*)" % path,
		}
	# Deny toolkit internal paths (token, audit log, onboarding flags).
	var rel := path.trim_prefix("user://")
	if rel.begins_with("addons/godot_mcp_toolkit/"):
		return {
			"ok": false,
			"error_code": "PATH_DENIED",
			"error_message": "user://addons/godot_mcp_toolkit/ is reserved for plugin internals (auth token, audit log)",
		}
	# Normalize + escape guard.
	var abs_path := ProjectSettings.globalize_path(path)
	var user_root := ProjectSettings.globalize_path("user://").simplify_path()
	if not abs_path.simplify_path().begins_with(user_root):
		return {
			"ok": false,
			"error_code": "PATH_DENIED",
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
