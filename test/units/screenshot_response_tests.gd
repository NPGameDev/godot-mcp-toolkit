@tool
extends RefCounted
## Unit tests for the shared screenshot response builder — the pure mode parse,
## save-path guard, disk persistence, and inline/disk/both payload shaping extracted
## so all three screenshot handlers share one wire shape without an editor viewport.
## Covers mode_of's default/valid/invalid resolution, the byte-identical inline
## payload, real disk persistence under user://screenshots/ (headless-writable), the
## both shape, and the two save-path rejections (non-.png, disallowed prefix).

const ScreenshotResponse := preload("res://addons/godot_mcp_toolkit/contract/screenshot_response.gd")

# The editor context's save-path allowlist; the runtime context is user:// only.
const _EDITOR_PREFIXES := ["res://", "user://screenshots/"]
const _RUNTIME_PREFIXES := ["user://screenshots/"]


static func run(testing) -> void:
	_test_mode_of(testing)
	_test_inline_payload(testing)
	_test_disk_persist(testing)
	_test_both_payload(testing)
	_test_save_path_rejections(testing)
	_test_auto_name_location(testing)


# A tiny real PNG so persistence and byte counts are exercised, not stubbed.
static func _sample_png() -> PackedByteArray:
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
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


# Inline mode returns exactly today's five keys, in order, with no path — and does
# NOT persist a supplied save_path (validated only).
static func _test_inline_payload(testing) -> void:
	testing.begin("ScreenshotResponse.build — inline")
	var png := _sample_png()

	var built := ScreenshotResponse.build({}, png, 4, 4, _EDITOR_PREFIXES)
	testing.ok(built.get("success") != false, "inline build did not fail")
	testing.ok(built.keys() == ["image_base64", "mime_type", "width", "height", "bytes"],
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
	testing.ok(built.keys() == ["path", "width", "height", "bytes", "mime_type"],
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
