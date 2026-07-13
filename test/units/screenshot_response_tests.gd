@tool
extends RefCounted
## Unit tests for the shared screenshot response builder — the pure mode parse,
## image_detail sizing, save-path guard, disk persistence, and inline/disk/both
## payload shaping extracted so all three screenshot handlers share one wire shape
## without an editor viewport. Covers mode_of's + detail_of's default/valid/invalid
## resolution, the pure image_detail_dims calculator (proportional, aspect-preserving,
## shrink-only), the inline payload with disclosure, real disk persistence under
## user://screenshots/ (headless-writable), the both shape, disk-stays-full-res while
## inline downscales, and the two save-path rejections (non-.png, disallowed prefix).

const ScreenshotResponse := preload("res://addons/godot_mcp_toolkit/contract/screenshot_response.gd")

# The editor context's save-path allowlist; the runtime context is user:// only.
const _EDITOR_PREFIXES := ["res://", "user://screenshots/"]
const _RUNTIME_PREFIXES := ["user://screenshots/"]


static func run(testing) -> void:
	_test_mode_of(testing)
	_test_detail_of(testing)
	_test_image_detail_dims(testing)
	_test_inline_payload(testing)
	_test_disclosure_fields(testing)
	_test_disk_persist(testing)
	_test_both_payload(testing)
	_test_both_disk_full_res(testing)
	_test_save_path_rejections(testing)
	_test_auto_name_location(testing)


# A tiny real PNG so persistence and byte counts are exercised, not stubbed.
static func _sample_png() -> PackedByteArray:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	return image.save_png_to_buffer()


# A smaller real PNG standing in for a downscaled inline buffer — a distinct byte
# size from _sample_png so the disk-vs-inline buffers are distinguishable.
static func _tiny_png() -> PackedByteArray:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLUE)
	return image.save_png_to_buffer()


# mode_of defaults to inline when absent, echoes a valid value, and returns "" for
# an unrecognized one so the caller can reject it.
static func _test_mode_of(testing) -> void:
	testing.begin("ScreenshotResponse.mode_of")
	testing.eq(ScreenshotResponse.mode_of({}), "inline", "absent → inline default")
	testing.eq(ScreenshotResponse.mode_of({"image_response_mode": "inline"}), "inline", "inline echoed")
	testing.eq(ScreenshotResponse.mode_of({"image_response_mode": "disk"}), "disk", "disk echoed")
	testing.eq(ScreenshotResponse.mode_of({"image_response_mode": "both"}), "both", "both echoed")
	testing.eq(ScreenshotResponse.mode_of({"image_response_mode": "bogus"}), "", "unrecognized → empty")
	print("")


# detail_of defaults to full when absent, echoes a valid level, and returns "" for an
# unrecognized value so the handler rejects a typo instead of falling through to full.
static func _test_detail_of(testing) -> void:
	testing.begin("ScreenshotResponse.detail_of")
	testing.eq(ScreenshotResponse.detail_of({}), "full", "absent → full default")
	testing.eq(ScreenshotResponse.detail_of({"image_detail": "full"}), "full", "full echoed")
	testing.eq(ScreenshotResponse.detail_of({"image_detail": "mid"}), "mid", "mid echoed")
	testing.eq(ScreenshotResponse.detail_of({"image_detail": "low"}), "low", "low echoed")
	testing.eq(ScreenshotResponse.detail_of({"image_detail": "huge"}), "", "unrecognized → empty")
	print("")


# The pure long-edge-cap calculator: proportional, aspect-preserving, shrink-only.
# full/unknown → native; mid caps the long edge to 1024, low to 512; a frame already
# within the cap is never upscaled; portrait caps the long edge (height) too.
static func _test_image_detail_dims(testing) -> void:
	testing.begin("ScreenshotResponse.image_detail_dims")
	# full / unknown → native, untouched.
	testing.eq(ScreenshotResponse.image_detail_dims(1920, 1080, "full"), Vector2i(1920, 1080),
		"full → native dims")
	testing.eq(ScreenshotResponse.image_detail_dims(1920, 1080, "bogus"), Vector2i(1920, 1080),
		"unknown level → native dims")
	# mid caps long edge to 1024; short edge scales proportionally (576 = round(1080*1024/1920)).
	testing.eq(ScreenshotResponse.image_detail_dims(1920, 1080, "mid"), Vector2i(1024, 576),
		"mid landscape → 1024 long edge, aspect preserved")
	testing.eq(576, roundi(1080.0 * 1024.0 / 1920.0), "short edge is the proportional round")
	# low caps long edge to 512.
	testing.eq(ScreenshotResponse.image_detail_dims(1920, 1080, "low"), Vector2i(512, 288),
		"low landscape → 512 long edge, aspect preserved")
	# Shrink-only: a frame already within the cap is returned unchanged (never upscaled).
	testing.eq(ScreenshotResponse.image_detail_dims(800, 600, "mid"), Vector2i(800, 600),
		"native long edge ≤ cap → unchanged (no upscale)")
	# Portrait: the long edge is the height, so it is the one capped.
	testing.eq(ScreenshotResponse.image_detail_dims(648, 1152, "mid"), Vector2i(576, 1024),
		"mid portrait → 1024 long edge (height), aspect preserved")
	print("")


# Inline mode returns the base64 keys plus the two disclosure keys, in order, with no
# path — and does NOT persist a supplied save_path (validated only).
static func _test_inline_payload(testing) -> void:
	testing.begin("ScreenshotResponse.build — inline")
	var png := _sample_png()

	var built := ScreenshotResponse.build({}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(built.get("success") != false, "inline build did not fail")
	testing.ok(built.keys() == ["image_base64", "mime_type", "width", "height", "bytes",
		"image_detail", "returned"],
		"inline key set + order pinned")
	testing.eq(str(built["mime_type"]), "image/png", "mime_type is image/png")
	testing.eq(int(built["width"]), 4, "width echoed")
	testing.eq(int(built["height"]), 4, "height echoed")
	testing.eq(int(built["bytes"]), png.size(), "bytes = PNG byte size")

	# A supplied save_path in inline mode is validated but never written: the payload
	# stays byte-identical to a no-save capture, and no file lands on disk.
	var save_target := "user://screenshots/inline_no_persist.png"
	var with_path := ScreenshotResponse.build(
		{"save_path": save_target}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(not with_path.has("path"), "inline + save_path → no path key")
	testing.ok(not FileAccess.file_exists(save_target), "inline + save_path → nothing persisted")
	print("")


# Every shape echoes the applied image_detail (default "full") and returned "WxH", so
# a size reduction is never silent; disk/both additionally carry a full-res hint.
static func _test_disclosure_fields(testing) -> void:
	testing.begin("ScreenshotResponse.build — image_detail / returned disclosure")
	var png := _sample_png()

	# Default (no image_detail) → "full"; returned mirrors the passed dims.
	var default_built := ScreenshotResponse.build({}, png, 4, 4, _EDITOR_PREFIXES)
	testing.eq(str(default_built["image_detail"]), "full", "absent image_detail → full")
	testing.eq(str(default_built["returned"]), "4x4", "returned is WxH of the passed dims")

	# An applied level is echoed verbatim on the inline shape.
	var mid_built := ScreenshotResponse.build({"image_detail": "mid"}, png, 4, 4, _EDITOR_PREFIXES)
	testing.eq(str(mid_built["image_detail"]), "mid", "applied image_detail echoed")

	# disk/both carry a full-res hint naming the saved path.
	var disk_target := "user://screenshots/disclosure_disk.png"
	var disk_built := ScreenshotResponse.build(
		{"image_response_mode": "disk", "save_path": disk_target}, png, 4, 4, _EDITOR_PREFIXES)
	testing.eq(str(disk_built["image_detail"]), "full", "disk echoes image_detail")
	testing.eq(str(disk_built["returned"]), "4x4", "disk returned is the full-res WxH")
	testing.ok(str(disk_built["hint"]).contains("full-res"), "disk hint states full-res")
	testing.ok(str(disk_built["hint"]).contains(str(disk_built["path"])), "disk hint names the path")
	DirAccess.remove_absolute(str(disk_built["path"]))

	var both_target := "user://screenshots/disclosure_both.png"
	var both_built := ScreenshotResponse.build(
		{"image_response_mode": "both", "save_path": both_target}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(str(both_built["hint"]).contains("Read it"), "both hint invites a Read for detail")
	DirAccess.remove_absolute(str(both_built["path"]))
	print("")


# Disk mode writes the PNG under user://screenshots/ (headless-writable), returns an
# absolute globalized path with no base64, and the file bytes match.
static func _test_disk_persist(testing) -> void:
	testing.begin("ScreenshotResponse.build — disk persists")
	var png := _sample_png()
	var save_target := "user://screenshots/disk_persist.png"

	var built := ScreenshotResponse.build(
		{"image_response_mode": "disk", "save_path": save_target}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(built.get("success") != false, "disk build did not fail")
	testing.ok(not built.has("image_base64"), "disk payload omits image_base64")
	testing.ok(built.keys() == ["path", "width", "height", "bytes", "mime_type",
		"image_detail", "returned", "hint"],
		"disk key set + order pinned")
	testing.eq(int(built["bytes"]), png.size(), "disk bytes = PNG byte size")

	var returned_path := str(built["path"])
	testing.ok(returned_path.begins_with("/") or returned_path.substr(1, 2) == ":/",
		"returned path is absolute (POSIX or Windows drive)")
	testing.eq(returned_path, ProjectSettings.globalize_path(save_target), "path is globalized save target")
	testing.ok(FileAccess.file_exists(returned_path), "PNG exists on disk")

	var on_disk := FileAccess.get_file_as_bytes(returned_path)
	testing.eq(on_disk.size(), png.size(), "on-disk byte size matches")

	DirAccess.remove_absolute(returned_path)
	print("")


# Both mode returns the inline shape plus the globalized file path, and persists.
static func _test_both_payload(testing) -> void:
	testing.begin("ScreenshotResponse.build — both")
	var png := _sample_png()
	var save_target := "user://screenshots/both_payload.png"

	var built := ScreenshotResponse.build(
		{"image_response_mode": "both", "save_path": save_target}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(built.get("success") != false, "both build did not fail")
	testing.ok(built.has("image_base64"), "both payload keeps image_base64")
	testing.ok(built.has("path"), "both payload adds path")
	testing.eq(str(built["path"]), ProjectSettings.globalize_path(save_target), "both path is globalized target")
	testing.ok(FileAccess.file_exists(str(built["path"])), "both persisted the PNG")

	DirAccess.remove_absolute(str(built["path"]))
	print("")


# The disk×detail orthogonality proof: with a downscaled inline buffer passed
# alongside the full-res buffer, the inline base64 + returned dims reflect the smaller
# buffer (the returned inline image) while the on-disk file stays full-res. This is
# what keeps image_detail:"low" + image_response_mode:"both" a downscaled inline over
# a full-res disk copy.
static func _test_both_disk_full_res(testing) -> void:
	testing.begin("ScreenshotResponse.build — both keeps disk full-res while inline downscales")
	var full := _sample_png()  # 4x4 stand-in for the full-res frame
	var inline := _tiny_png()  # 2x2 stand-in for the downscaled inline
	var save_target := "user://screenshots/both_full_res.png"

	var built := ScreenshotResponse.build(
		{"image_response_mode": "both", "image_detail": "low", "save_path": save_target},
		full, 4, 4, _EDITOR_PREFIXES, inline, 2, 2)
	testing.ok(built.get("success") != false, "both build did not fail")
	# The top-level dims + returned describe the RETURNED inline image (downscaled 2x2),
	# per the contract ("returned" = the returned inline image's dims).
	testing.eq(int(built["width"]), 2, "inline width is the downscaled width")
	testing.eq(int(built["height"]), 2, "inline height is the downscaled height")
	testing.eq(str(built["returned"]), "2x2", "returned reports the downscaled inline dims")
	# But the on-disk file holds the FULL-res bytes — disk is never downscaled.
	var on_disk := FileAccess.get_file_as_bytes(str(built["path"]))
	testing.eq(on_disk.size(), full.size(), "on-disk file is the full-res PNG (not the 2x2 inline)")
	# The inline base64 decodes to the downscaled buffer, not the full-res one.
	var decoded := Marshalls.base64_to_raw(str(built["image_base64"]))
	testing.eq(decoded.size(), inline.size(), "inline base64 is the downscaled buffer")
	testing.eq(int(built["bytes"]), inline.size(), "bytes reports the inline (returned) buffer size")
	testing.eq(str(built["image_detail"]), "low", "applied image_detail echoed")
	# The full-res hint still names the saved file.
	testing.ok(str(built["hint"]).contains("full-res"), "both hint states the saved file is full-res")

	DirAccess.remove_absolute(str(built["path"]))
	print("")


# A non-.png save_path is INVALID_PARAMS; a path outside the allowlist (res:// against
# the runtime user://-only prefixes) is PATH_DENIED — both before any write.
static func _test_save_path_rejections(testing) -> void:
	testing.begin("ScreenshotResponse.build — save-path rejections")
	var png := _sample_png()

	var non_png := ScreenshotResponse.build(
		{"image_response_mode": "disk", "save_path": "user://screenshots/shot.jpg"},
		png, 4, 4, _EDITOR_PREFIXES)
	testing.eq(non_png.get("success"), false, "non-.png → failure")
	testing.eq(str(non_png.get("code", "")), "INVALID_PARAMS", "non-.png → INVALID_PARAMS")

	# res:// is outside the runtime allowlist → PATH_DENIED (FileGuard prefix reject).
	var disallowed := ScreenshotResponse.build(
		{"image_response_mode": "disk", "save_path": "res://shot.png"},
		png, 4, 4, _RUNTIME_PREFIXES)
	testing.eq(disallowed.get("success"), false, "disallowed prefix → failure")
	testing.eq(str(disallowed.get("code", "")), "PATH_DENIED", "disallowed prefix → PATH_DENIED")

	# A bad mode value fails as INVALID_PARAMS before any save-path handling.
	var bad_mode := ScreenshotResponse.build(
		{"image_response_mode": "sideways"}, png, 4, 4, _EDITOR_PREFIXES)
	testing.eq(bad_mode.get("success"), false, "bad mode → failure")
	testing.eq(str(bad_mode.get("code", "")), "INVALID_PARAMS", "bad mode → INVALID_PARAMS")
	print("")


# With no save_path, disk mode auto-names a unique file under user://screenshots/.
static func _test_auto_name_location(testing) -> void:
	testing.begin("ScreenshotResponse.build — auto-name location")
	var png := _sample_png()

	var built := ScreenshotResponse.build(
		{"image_response_mode": "disk"}, png, 4, 4, _RUNTIME_PREFIXES)
	testing.ok(built.get("success") != false, "auto-named disk build did not fail")
	var returned_path := str(built["path"])
	var screenshots_root := ProjectSettings.globalize_path("user://screenshots/")
	testing.ok(returned_path.begins_with(screenshots_root), "auto-named file lands under user://screenshots/")
	testing.ok(returned_path.ends_with(".png"), "auto-named file is a .png")
	testing.ok(FileAccess.file_exists(returned_path), "auto-named PNG exists on disk")

	DirAccess.remove_absolute(returned_path)
	print("")
