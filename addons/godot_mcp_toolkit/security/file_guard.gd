@tool
extends RefCounted
## Filesystem boundary enforcement.
##
## Every command that touches the filesystem calls resolve_safe() to
## validate and canonicalize the path before any I/O. Default allows
## res:// only; callers opt in to additional prefixes (e.g.
## user://screenshots/) via the allowed_prefixes parameter. Every command
## that deletes a res:// path calls resolve_safe_delete() instead, which
## also refuses version-control, engine and project metadata.
##
## Every check against a host folder (the project root, res://addons, the
## toolkit's source and its user:// folder) compares a case-folded form of the
## path with Windows alias spellings cut away, because the Windows and macOS
## filesystems open the folder under any of those spellings.
##
## resolve_safe_user() validates user:// paths: rejects traversal,
## re-asserts the user:// boundary after canonicalization, then returns
## the globalized absolute path.
##
## Both resolvers route their shared traversal-reject (_has_traversal) and
## post-canonicalize boundary re-check (_within_boundary) through one helper
## each. They keep DIFFERENT return shapes on purpose (documented at each
## function): resolve_safe() returns the
## ORIGINAL virtual res:// path — callers hand it straight to engine I/O, which
## speaks res://; resolve_safe_user() returns the GLOBALIZED absolute path —
## save.* needs a real OS path for FileAccess.

## The folder that holds the toolkit's own source. Test a path against it with
## [method is_toolkit_source].
const TOOLKIT_SOURCE_DIR := "res://addons/godot_mcp_toolkit/"

## Ends every refusal of a host folder, so a caller who spelled the folder another way
## learns why the path counts as that folder.
const SAME_FOLDER_NOTE := "letter case and Windows alias spellings (a trailing dot or space, an NTFS stream, an 8.3 short name) count as the same folder"

const _PROJECT_ROOT := "res://"
const _ADDONS_DIR := "res://addons"
const _USER_ADDONS_DIR := "addons/"
const _USER_TOOLKIT_DIR := "addons/godot_mcp_toolkit"

## The letters a case-insensitive filesystem can read as ASCII that one case call misses:
## [code]to_lower()[/code] keeps the dotless i and the long s, [code]to_upper()[/code] keeps
## the Kelvin sign and the dotted capital I, and before Godot 4.4 the engine's case tables
## fold only the dotless i. Mapping them first gives the same verdict on every version.
const _FOLD_MAP := {
	"\u0131": "i", # dotless i
	"\u017f": "s", # long s, which APFS reads as s
	"\u212a": "k", # Kelvin sign, which APFS reads as k
	"\u0130": "i", # dotted capital I
}

## Files the engine reads to load the project, refused by [method resolve_safe_delete].
const _RESERVED_FILE_NAMES: Array[String] = ["project.godot", "override.cfg"]

## Matches a Windows 8.3 short name, such as [code]GIT~1[/code] or
## [code]PROJEC~1.GOD[/code], which Windows resolves to the long name it abbreviates.
static var _short_name_re: RegEx = _compile_short_name_re()


static func _compile_short_name_re() -> RegEx:
	var re := RegEx.new()
	re.compile("^[^.~]{0,6}~[0-9]+(\\.[^.]{0,3})?$")
	return re


## Whether [param path] is the toolkit's own source folder or a file inside it, under any
## spelling the filesystem resolves to it: another letter case, back or doubled slashes, a
## trailing dot or space on a folder name, or an NTFS stream suffix.
##
## The folder matches whole, so a sibling such as
## [code]res://addons/godot_mcp_toolkit_extras/[/code] is not the toolkit's. On a
## case-sensitive volume a folder that differs from it only by case counts as the toolkit's
## too: a refusal there costs less than a bypass on Windows or macOS.
##
## Returns [code]true[/code] for the folder itself and every path under it.
static func is_toolkit_source(path: String) -> bool:
	var form := _comparison_form(path)
	return form == TOOLKIT_SOURCE_DIR.trim_suffix("/") or form.begins_with(TOOLKIT_SOURCE_DIR)


## Whether [param path] is a host folder, one a delete must never remove: the project root,
## [code]res://addons[/code] or the toolkit's source folder, under any spelling the
## filesystem resolves to one of them.
##
## Returns [code]true[/code] for each host folder and every path inside the toolkit's source.
static func is_host_folder(path: String) -> bool:
	var form := _comparison_form(path)
	return form == _PROJECT_ROOT or form == _ADDONS_DIR or _may_reach_toolkit_source(form)


## Validate and resolve a user:// path.
## Returns { ok: true, absolute_path } on success,
## { ok: false, error_code, error_message } on failure.
static func resolve_safe_user(path: String) -> Dictionary:
	var normalized := path.replace("\\", "/")
	# Reject .. segments — directory traversal. (resolve_safe_user reports
	# traversal as INVALID_PATH, where resolve_safe reports PATH_DENIED, so the
	# shared check returns a kind and each caller maps it to its own code.)
	if _has_traversal(normalized):
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
	# Deny toolkit internal paths (token, audit log, onboarding flags). This is
	# the keystone the res:// resolver mirrors: the plugin's own user-data dir is
	# off-limits so a tool call can't tamper with the auth token or audit log. The
	# folder itself counts too: a path naming it without a trailing slash reaches it.
	var rel := _comparison_form(path).trim_prefix("user://")
	if rel == _USER_TOOLKIT_DIR or rel.begins_with(_USER_TOOLKIT_DIR + "/") \
			or _is_short_name_under(rel, _USER_ADDONS_DIR):
		return {
			"ok": false,
			"error_code": "PATH_DENIED",
			"error_message": "user://addons/godot_mcp_toolkit/ is reserved for plugin internals (auth token, audit log); %s" % SAME_FOLDER_NOTE,
		}
	# Re-assert the user:// boundary after canonicalization (lexical simplify +
	# prefix substitution — NOT an OS-symlink resolution; localhost single-user
	# threat model), then return the globalized absolute path (save.* needs a real
	# OS path for FileAccess — this is why the shape differs from resolve_safe).
	if not _within_boundary(path, "user://"):
		return {
			"ok": false,
			"error_code": "PATH_DENIED",
			"error_message": "path %s resolves outside the user data dir after canonicalization" % path,
		}
	return {"ok": true, "absolute_path": ProjectSettings.globalize_path(path)}


static func resolve_safe(
	input: String, allowed_prefixes: Array = ["res://"],
) -> Dictionary:
	if input.strip_edges().is_empty():
		return _denied("empty path")

	var normalized := input.replace("\\", "/")

	# Reject ".." path segments — directory traversal.
	if _has_traversal(normalized):
		return _denied("path contains '..': %s" % input)

	# Reject absolute OS paths (drive letters, UNC, Unix root).
	if normalized.length() >= 2 and normalized[1] == ":":
		return _denied("absolute OS path: %s" % input)
	# A leading "/" also catches UNC paths: the backslash->slash normalize
	# above rewrites "\\server\share" as "//server/share", so no separate
	# UNC branch is needed.
	if normalized.begins_with("/") \
			and not normalized.begins_with("res://") \
			and not normalized.begins_with("user://"):
		return _denied("absolute OS path: %s" % input)

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

	# Deny the plugin's own source dir, mirroring the user:// keystone above:
	# res://addons/godot_mcp_toolkit/ holds the toolkit's GDScript, so a tool call
	# must not read or rewrite it (FileGuard is operation-agnostic — denying here
	# covers both reads and writes). Check the SIMPLIFIED VIRTUAL path so a
	# traversal that lands inside (res://foo/../addons/godot_mcp_toolkit/x.gd) is
	# caught too. Other addons (res://addons/<other>/) stay editable.
	var canonical := normalized.simplify_path()
	if _may_reach_toolkit_source(canonical):
		return _denied(
			"res://addons/godot_mcp_toolkit/ is the plugin's own source and is protected; %s" % SAME_FOLDER_NOTE)

	# Canonicalize and re-assert the path still resolves under its boundary root
	# (lexical simplify + prefix substitution — NOT OS-symlink resolution). On
	# success the ORIGINAL virtual res:// path is returned unchanged: callers hand
	# it straight to engine I/O, which speaks res:// (this is why the shape differs
	# from resolve_safe_user, which returns a globalized absolute path).
	if normalized.begins_with("user://"):
		if not _within_boundary(input, "user://"):
			return _denied("path escapes user:// boundary: %s" % input)
	else:
		if not _within_boundary(input, "res://"):
			return _denied("path escapes project boundary: %s" % input)

	return {"path": input, "error": null}


## Validate a res:// path a delete command is about to remove.
##
## Runs [method resolve_safe], then refuses reserved paths: any segment that starts
## with a dot ([code].git[/code], [code].godot[/code], [code].mcp.json[/code] and
## everything inside a dot-folder), and a file named [code]project.godot[/code] or
## [code]override.cfg[/code] at any depth. It also refuses any segment shaped like a
## Windows alias, whatever the name, because Windows can resolve it to a reserved
## one: a [code]:[/code] (an NTFS stream), a trailing dot or space, an 8.3 short
## name. The check is case-insensitive because the Windows and macOS filesystems
## are. A developer who means to delete one of these does it by hand.
##
## Returns the same shape as [method resolve_safe].
static func resolve_safe_delete(path: String) -> Dictionary:
	var guard := resolve_safe(path)
	if guard["error"] != null:
		return guard
	var relative := path.replace("\\", "/").simplify_path().trim_prefix("res://")
	for segment: String in relative.split("/", false):
		if _is_reserved_segment(segment.to_lower()):
			return _denied(
					"%s is reserved (version control, engine or project metadata); the delete tools refuse it, so delete it by hand if you mean to" % path)
	return guard


## Whether a lowercased path segment names a reserved entry or has a Windows alias shape.
static func _is_reserved_segment(segment: String) -> bool:
	if segment.begins_with(".") or segment in _RESERVED_FILE_NAMES:
		return true
	if segment.contains(":") or segment.ends_with(".") or segment.ends_with(" "):
		return true
	return _short_name_re.search(segment) != null


## Whether [param path] may open the toolkit's source folder: [method is_toolkit_source],
## or an 8.3 short name directly under [code]res://addons/[/code]. Windows expands a short
## name to the long name it abbreviates, and the name alone cannot tell which folder that
## is, so a real folder named like [code]v2~1[/code] is refused too. The short-name test
## stays out of [method is_toolkit_source], whose engine-supplied paths never carry a short
## name, so such a folder is still exported and reloaded like any other.
static func _may_reach_toolkit_source(path: String) -> bool:
	return is_toolkit_source(path) or _is_short_name_under(_comparison_form(path), _ADDONS_DIR + "/")


## The spelling every host-folder comparison uses: backslashes as slashes, simplified,
## case-folded, and each segment cut to the name Windows opens, the text before any
## [code]:[/code] (an NTFS stream) without trailing dots or spaces. Comparison only: the
## engine still gets the caller's path.
static func _comparison_form(path: String) -> String:
	var form := _fold(path.replace("\\", "/").simplify_path())
	var head := ""
	var scheme_end := form.find("://")
	if scheme_end > 0:
		head = form.substr(0, scheme_end + 3)
		form = form.substr(scheme_end + 3)
	var names := PackedStringArray()
	for segment: String in form.split("/", false):
		var name := segment.get_slice(":", 0).rstrip(". ")
		if not name.is_empty():
			names.append(name)
	return head + "/".join(names)


## Folds [param text] for a comparison against the lowercase ASCII host-folder names. A
## case-insensitive filesystem matches names whatever their case, and macOS's APFS also
## reads the long s as s and the Kelvin sign as k, which neither case call alone folds.
static func _fold(text: String) -> String:
	var mapped := text
	for letter: String in _FOLD_MAP:
		mapped = mapped.replace(letter, str(_FOLD_MAP[letter]))
	return mapped.to_upper().to_lower()


## Whether the first segment of the comparison form [param form] below [param parent] has
## the shape of a Windows 8.3 short name.
static func _is_short_name_under(form: String, parent: String) -> bool:
	if not form.begins_with(parent):
		return false
	return _short_name_re.search(form.substr(parent.length()).get_slice("/", 0)) != null


## True if any slash-delimited segment is exactly "..". Shared by both
## resolvers so the traversal reject is defined once; each caller maps a hit to
## its own error code (resolve_safe → PATH_DENIED, resolve_safe_user →
## INVALID_PATH). Expects a forward-slash-normalized path.
static func _has_traversal(normalized: String) -> bool:
	for segment in normalized.split("/"):
		if segment == "..":
			return true
	return false


## Re-assert that `input` still resolves under `boundary_prefix` (e.g. "res://"
## or "user://") after canonicalization. globalize both sides, simplify, compare
## prefixes. Lexical only — simplify_path + globalize_path are string ops, NOT an
## OS-symlink resolution. Shared by both resolvers so the re-check is defined
## once; each caller phrases its own denial message.
static func _within_boundary(input: String, boundary_prefix: String) -> bool:
	var simplified := ProjectSettings.globalize_path(input).simplify_path()
	var root := ProjectSettings.globalize_path(boundary_prefix).simplify_path()
	return simplified.begins_with(root)


static func _denied(reason: String) -> Dictionary:
	return {"path": "", "error": "PATH_DENIED", "reason": reason}
