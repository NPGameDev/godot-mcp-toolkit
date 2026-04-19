@tool
extends RefCounted
## Filesystem boundary enforcement (I4).
##
## Every command that touches the filesystem calls resolve_safe() to
## validate and canonicalize the path before any I/O. Default allows
## res:// only; callers opt in to additional prefixes (e.g.
## user://screenshots/) via the allowed_prefixes parameter.


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
