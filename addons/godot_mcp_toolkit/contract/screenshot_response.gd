@tool
extends RefCounted
## Shared screenshot response builder — mode parse, save-path guard, disk persist,
## and inline/disk/both payload shaping for the three screenshot handlers.
##
## The [code]image_response_mode[/code] param selects how a capture is returned:
## [code]"inline"[/code] (default) embeds the base64 PNG in the response;
## [code]"disk"[/code] persists the PNG and returns only its file path (for very
## large captures or to conserve context tokens); [code]"both"[/code] does both.
## A [code]save_path[/code] names the destination (validated against the caller's
## allowlist, [code].png[/code] required); when omitted in disk/both an auto-named
## file lands under [code]user://screenshots/[/code]. The editor and runtime
## handlers share this one builder so the wire shape stays identical across all
## three call sites.[br]
## [br]
## Runtime-clean by construction — it preloads only [code]security/file_guard.gd[/code]
## and names value types plus [MCPToolkitError] (a runtime-safe global class),
## [FileAccess], [DirAccess], [ProjectSettings], [Marshalls], and [Time], never an
## editor class. An editor symbol anywhere in this static graph would parse-fail the
## runtime autoload in an unstripped export (godotengine/godot#91713), and the
## runtime server preloads this file; keep it editor-free.

const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")

## Directory auto-named captures are written to when disk/both mode omits a save_path.
const _AUTO_NAME_DIR := "user://screenshots/"


## Returns the requested response mode: [code]"inline"[/code], [code]"disk"[/code],
## or [code]"both"[/code].
##
## Absent [code]image_response_mode[/code] defaults to [code]"inline"[/code]. A
## present-but-unrecognized value returns [code]""[/code] so the caller can reject
## it as INVALID_PARAMS. [param parameters] is the raw JSON-RPC parameter dict.
static func mode_of(parameters: Dictionary) -> String:
	if not parameters.has("image_response_mode"):
		return "inline"
	var mode := str(parameters.get("image_response_mode", ""))
	if mode == "inline" or mode == "disk" or mode == "both":
		return mode
	return ""


## Shapes the screenshot response for the requested mode, persisting the PNG when
## disk/both, and returns the data Dictionary the handler wraps in
## [method MCPToolkitSuccess.ok].
##
## [param parameters] is the raw parameter dict (read for [code]image_response_mode[/code]
## and [code]save_path[/code]); [param png_bytes] is the encoded PNG;
## [param width] / [param height] are the captured image dimensions;
## [param allowed_save_prefixes] is the save-path allowlist for this context
## (editor: [code]res://[/code] + [code]user://screenshots/[/code]; runtime:
## [code]user://screenshots/[/code] only).[br]
## [br]
## A [code]save_path[/code] is validated whenever present, in ANY mode: it must pass
## [method FileGuard.resolve_safe] against [param allowed_save_prefixes] and end in
## [code].png[/code]. In inline mode it is validated but NOT persisted (the response
## stays byte-identical to a no-save capture). In disk/both mode the target is the
## given [code]save_path[/code], else an auto-named file under
## [code]user://screenshots/[/code]; the directory is created and the PNG written.[br]
## [br]
## Returns the shaped payload on success:
## [code]{image_base64, mime_type, width, height, bytes}[/code] for inline;
## [code]{path, width, height, bytes, mime_type}[/code] (no base64) for disk;
## the inline shape plus [code]path[/code] for both. A returned [code]path[/code] is
## the globalized absolute file path. On failure it returns a
## [method MCPToolkitError.fail] dict directly (identified by
## [code]"success": false[/code]): INVALID_PARAMS (bad mode value or non-[code].png[/code]
## save_path), PATH_DENIED (FileGuard rejection), or INTERNAL (mkdir / write failure).
static func build(parameters: Dictionary, png_bytes: PackedByteArray, width: int, height: int,
		allowed_save_prefixes: Array) -> Dictionary:
	var mode := mode_of(parameters)
	if mode.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS",
			"image_response_mode must be one of [inline, disk, both] (got %s)"
			% str(parameters.get("image_response_mode", "")))

	var save_path := str(parameters.get("save_path", ""))

	# Validate a supplied save_path in every mode, so inline callers get the same
	# deterministic rejection they would in disk/both rather than a silent accept.
	if not save_path.is_empty():
		var validation := _validate_save_path(save_path, allowed_save_prefixes)
		if validation.get("success") == false:
			return validation

	if mode == "inline":
		return _inline_payload(png_bytes, width, height)

	# disk / both: resolve the destination, ensure the directory, write the PNG.
	var target := save_path if not save_path.is_empty() else _auto_name()
	var persisted := _persist_png(target, png_bytes)
	if persisted.get("success") == false:
		return persisted
	var globalized := str(persisted["path"])

	if mode == "both":
		var payload := _inline_payload(png_bytes, width, height)
		payload["path"] = globalized
		return payload
	return _disk_payload(globalized, png_bytes, width, height)


## Validates [param save_path] against [param allowed_prefixes] via FileGuard plus a
## [code].png[/code]-suffix check. Returns [code]{}[/code] when valid, else the
## PATH_DENIED / INVALID_PARAMS [method MCPToolkitError.fail] dict.
static func _validate_save_path(save_path: String, allowed_prefixes: Array) -> Dictionary:
	var guard := FileGuard.resolve_safe(save_path, allowed_prefixes)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if not save_path.ends_with(".png"):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"save_path must end with .png: %s" % save_path)
	return {}


## Writes [param png_bytes] to [param target] (a validated res:// or user:// path),
## creating the parent directory. Returns [code]{"path": <globalized absolute path>}[/code]
## on success, else an INTERNAL [method MCPToolkitError.fail] dict.
static func _persist_png(target: String, png_bytes: PackedByteArray) -> Dictionary:
	var directory_path := target.get_base_dir()
	if not directory_path.is_empty():
		var mkdir_error := DirAccess.make_dir_recursive_absolute(directory_path)
		if mkdir_error != OK and mkdir_error != ERR_ALREADY_EXISTS:
			return MCPToolkitError.fail("INTERNAL",
				"could not create %s (err %d)" % [directory_path, mkdir_error])
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return MCPToolkitError.fail("INTERNAL",
			"could not open %s for writing (err %d)" % [target, FileAccess.get_open_error()])
	file.store_buffer(png_bytes)
	file.close()
	return {"path": ProjectSettings.globalize_path(target)}


## The inline payload: the base64 PNG plus its metadata, in the historical key order
## every existing caller emits (byte-identical to a pre-mode capture).
static func _inline_payload(png_bytes: PackedByteArray, width: int, height: int) -> Dictionary:
	return {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": width,
		"height": height,
		"bytes": png_bytes.size(),
	}


## The lean disk payload: the file path plus metadata, with NO embedded base64.
static func _disk_payload(globalized_path: String, png_bytes: PackedByteArray,
		width: int, height: int) -> Dictionary:
	return {
		"path": globalized_path,
		"width": width,
		"height": height,
		"bytes": png_bytes.size(),
		"mime_type": "image/png",
	}


## A unique auto-name under [code]user://screenshots/[/code] for a save-less
## disk/both capture. Timestamp for human ordering plus a microsecond tick so two
## captures in the same second never collide.
static func _auto_name() -> String:
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "-")
	return "%sscreenshot_%s_%d.png" % [_AUTO_NAME_DIR, stamp, Time.get_ticks_usec()]
