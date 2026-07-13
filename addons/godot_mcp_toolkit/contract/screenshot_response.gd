@tool
extends RefCounted
## Shared screenshot response builder — mode parse, [code]image_detail[/code] sizing,
## save-path guard, disk persist, and inline/disk/both payload shaping for the three
## screenshot handlers.
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
## The [code]image_detail[/code] param ([code]"full"[/code]/[code]"mid"[/code]/
## [code]"low"[/code]) caps the [b]inline[/b] image's long edge; this file owns the
## pure [method image_detail_dims] calculator (the capture handler applies the
## [Image] resize — this stays a pure shaper) and echoes the applied level plus the
## returned [code]"WxH"[/code] so a size reduction is never silent. A disk/both
## response also carries a hint that the saved file is full resolution.[br]
## [br]
## Runtime-clean by construction — it preloads only [code]security/file_guard.gd[/code]
## and names value types plus [MCPToolkitError] (a runtime-safe global class),
## [FileAccess], [DirAccess], [ProjectSettings], [Marshalls], [Image] (a core class),
## and [Time], never an editor class. An editor symbol anywhere in this static graph
## would parse-fail the runtime autoload in an unstripped export
## (godotengine/godot#91713), and the runtime server preloads this file; keep it
## editor-free.

const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")

## Directory auto-named captures are written to when disk/both mode omits a save_path.
const _AUTO_NAME_DIR := "user://screenshots/"

## Long-edge cap (px) per image_detail level for the inline image. Provisional
## targets: "mid" keeps HUD text readable, "low" preserves gross layout/motion only;
## "full" is absent here (never caps). Tuned values pending a live fidelity check.
const IMAGE_DETAIL_CAPS := {"mid": 1024, "low": 512}


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


## Returns the requested inline-resolution level: [code]"full"[/code],
## [code]"mid"[/code], or [code]"low"[/code].
##
## Absent [code]image_detail[/code] defaults to [code]"full"[/code] (native, no cap).
## A present-but-unrecognized value returns [code]""[/code] so each capture handler
## can reject it as INVALID_PARAMS rather than silently falling through to full-res.
## [param parameters] is the raw JSON-RPC parameter dict.
static func detail_of(parameters: Dictionary) -> String:
	if not parameters.has("image_detail"):
		return "full"
	var detail := str(parameters.get("image_detail", ""))
	if detail == "full" or detail == "mid" or detail == "low":
		return detail
	return ""


## Target inline dimensions for [param detail] applied to a native
## [param width]×[param height] frame.
##
## Proportional, aspect-preserving, and shrink-only: returns the native dims
## unchanged for [code]"full"[/code], for an unknown value, or when the long edge is
## already within the level's cap (never upscales). The reduced levels cap the long
## edge to [constant IMAGE_DETAIL_CAPS] and scale the short edge to match. Pure and
## deterministic — the sizing decision lives here so it is unit-testable without an
## editor, while the capture handler owns the [method Image.resize] call.
static func image_detail_dims(width: int, height: int, detail: String) -> Vector2i:
	if not IMAGE_DETAIL_CAPS.has(detail):
		return Vector2i(width, height)
	var cap: int = IMAGE_DETAIL_CAPS[detail]
	var long_edge := maxi(width, height)
	if long_edge <= cap:
		return Vector2i(width, height)
	var scale := float(cap) / float(long_edge)
	return Vector2i(maxi(1, roundi(width * scale)), maxi(1, roundi(height * scale)))


## Shapes the screenshot response for the requested mode, persisting the PNG when
## disk/both, and returns the data Dictionary the handler wraps in
## [method MCPToolkitSuccess.ok].
##
## [param parameters] is the raw parameter dict (read for [code]image_response_mode[/code],
## [code]image_detail[/code], and [code]save_path[/code]); [param png_bytes] is the
## [b]full-res[/b] encoded PNG and [param width] / [param height] its native
## dimensions — always what a disk copy persists; [param allowed_save_prefixes] is
## the save-path allowlist for this context (editor: [code]res://[/code] +
## [code]user://screenshots/[/code]; runtime: [code]user://screenshots/[/code] only).[br]
## [br]
## The [b]inline[/b] image is separable so [code]image_detail[/code] can downscale it
## while disk stays full-res: pass a pre-downscaled [param inline_png_bytes] +
## [param inline_width] / [param inline_height] and the inline base64 uses those
## instead of the full-res buffer. Left at the defaults (empty / [code]-1[/code]), the
## inline reuses the full-res buffer — the [code]"full"[/code] path, byte-identical to
## a pre-[code]image_detail[/code] capture. The caller (not this pure shaper) owns the
## [method Image.resize]. Every payload echoes the applied [code]image_detail[/code]
## plus [code]returned[/code] ([code]"WxH"[/code] of the returned inline, or of the
## full-res file in disk mode) so a size reduction is never silent.[br]
## [br]
## A [code]save_path[/code] is validated whenever present, in ANY mode: it must pass
## [method FileGuard.resolve_safe] against [param allowed_save_prefixes] and end in
## [code].png[/code]. In inline mode it is validated but NOT persisted (the response
## stays byte-identical to a no-save capture). In disk/both mode the target is the
## given [code]save_path[/code], else an auto-named file under
## [code]user://screenshots/[/code]; the directory is created and the full-res PNG
## written, and a [code]hint[/code] discloses that the saved file is full resolution.[br]
## [br]
## Returns the shaped payload on success:
## [code]{image_base64, mime_type, width, height, bytes, image_detail, returned}[/code]
## for inline; [code]{path, width, height, bytes, mime_type, image_detail, returned,
## hint}[/code] (no base64) for disk; the inline shape plus [code]path[/code] and
## [code]hint[/code] for both. A returned [code]path[/code] is the globalized absolute
## file path. On failure it returns a [method MCPToolkitError.fail] dict directly
## (identified by [code]"success": false[/code]): INVALID_PARAMS (bad mode value or
## non-[code].png[/code] save_path), PATH_DENIED (FileGuard rejection), or INTERNAL
## (mkdir / write failure).
static func build(parameters: Dictionary, png_bytes: PackedByteArray, width: int, height: int,
		allowed_save_prefixes: Array, inline_png_bytes: PackedByteArray = PackedByteArray(),
		inline_width: int = -1, inline_height: int = -1) -> Dictionary:
	var mode := mode_of(parameters)
	if mode.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS",
			"image_response_mode must be one of [inline, disk, both] (got %s)"
			% str(parameters.get("image_response_mode", "")))

	var save_path := str(parameters.get("save_path", ""))
	# The applied inline-resolution level, echoed on every shape. The handler has
	# already validated the enum; absent → "full" (native). Disk mode returns no inline
	# image, so its "returned" reports the full-res dims regardless of this value.
	var detail := str(parameters.get("image_detail", "full"))

	# The inline image is the pre-downscaled buffer when the caller supplied one, else
	# the full-res buffer (the "full" path). Disk mode ignores these — no inline.
	var has_inline_override := inline_png_bytes.size() > 0 and inline_width >= 0 and inline_height >= 0
	var inline_bytes := inline_png_bytes if has_inline_override else png_bytes
	var inline_w := inline_width if has_inline_override else width
	var inline_h := inline_height if has_inline_override else height

	# Validate a supplied save_path in every mode, so inline callers get the same
	# deterministic rejection they would in disk/both rather than a silent accept.
	if not save_path.is_empty():
		var validation := _validate_save_path(save_path, allowed_save_prefixes)
		if validation.get("success") == false:
			return validation

	if mode == "inline":
		return _inline_payload(inline_bytes, inline_w, inline_h, detail)

	# disk / both: resolve the destination, ensure the directory, write the full-res PNG.
	var target := save_path if not save_path.is_empty() else _auto_name()
	var persisted := _persist_png(target, png_bytes)
	if persisted.get("success") == false:
		return persisted
	var globalized := str(persisted["path"])

	if mode == "both":
		var payload := _inline_payload(inline_bytes, inline_w, inline_h, detail)
		payload["path"] = globalized
		payload["hint"] = _full_res_hint(globalized)
		return payload
	# Disk-only: the returned artifact is the full-res file, so "returned" = full-res dims.
	return _disk_payload(globalized, png_bytes, width, height, detail)


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


## The inline payload: the base64 PNG plus its metadata and the applied-detail
## disclosure, with the historical keys first and the two disclosure keys appended.
static func _inline_payload(png_bytes: PackedByteArray, width: int, height: int,
		detail: String) -> Dictionary:
	return {
		"image_base64": Marshalls.raw_to_base64(png_bytes),
		"mime_type": "image/png",
		"width": width,
		"height": height,
		"bytes": png_bytes.size(),
		"image_detail": detail,
		"returned": "%dx%d" % [width, height],
	}


## The lean disk payload: the file path plus metadata and the applied-detail
## disclosure, with NO embedded base64. [param width] / [param height] are the
## full-res dims of the saved file (disk mode never downscales).
static func _disk_payload(globalized_path: String, png_bytes: PackedByteArray,
		width: int, height: int, detail: String) -> Dictionary:
	return {
		"path": globalized_path,
		"width": width,
		"height": height,
		"bytes": png_bytes.size(),
		"mime_type": "image/png",
		"image_detail": detail,
		"returned": "%dx%d" % [width, height],
		"hint": _full_res_hint(globalized_path),
	}


## The disk-persist disclosure hint: the saved file is always full resolution
## regardless of [code]image_detail[/code], so an agent can read it for pixel detail
## instead of re-capturing. [param globalized_path] is the saved file's absolute path.
static func _full_res_hint(globalized_path: String) -> String:
	return "Saved full-res → %s. Read it for pixel detail without re-capturing." % globalized_path


## A unique auto-name under [code]user://screenshots/[/code] for a save-less
## disk/both capture. Timestamp for human ordering plus a microsecond tick so two
## captures in the same second never collide.
static func _auto_name() -> String:
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "-")
	return "%sscreenshot_%s_%d.png" % [_AUTO_NAME_DIR, stamp, Time.get_ticks_usec()]
