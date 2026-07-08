@tool
extends RefCounted
## spriteframes.* command handlers — SpriteFrames resource creation and editing.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("spriteframes.create", func(p: Dictionary) -> Dictionary:
		return _cmd_create(p)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("spriteframes.edit", func(p: Dictionary) -> Dictionary:
		return _cmd_edit(p)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("spriteframes.from_spritesheet", func(p: Dictionary) -> Dictionary:
		return _cmd_from_spritesheet(p)
	, MCPToolkitCommandOptions.new().mark_scene_independent())


# -- Commands -----------------------------------------------------------------


static func _cmd_create(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "animations"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var animations_raw = parameters.get("animations", null)

	if typeof(animations_raw) != TYPE_ARRAY or animations_raw.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "animations must be a non-empty Array")

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tres":
		return MCPToolkitError.fail("INVALID_PATH",
			"spriteframes.create writes .tres files (got %s)" % file_path)

	# Idempotency: if file already exists, return early.
	if FileAccess.file_exists(file_path):
		return MCPToolkitSuccess.ok({"status": "returned", "path": file_path})

	var sf := SpriteFrames.new()
	var anim_info := []

	for anim_raw in animations_raw:
		if typeof(anim_raw) != TYPE_DICTIONARY:
			return MCPToolkitError.fail("INVALID_PARAMS", "each animation must be a Dictionary")

		var anim_name := str(anim_raw.get("name", ""))
		if anim_name.is_empty():
			return MCPToolkitError.fail("INVALID_PARAMS", "animation name is required")

		var fps: float = float(anim_raw.get("fps", 5.0))
		var loop: bool = bool(anim_raw.get("loop", true))
		var frames_raw = anim_raw.get("frames", [])

		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, fps)
		sf.set_animation_loop(anim_name, loop)

		if typeof(frames_raw) == TYPE_ARRAY:
			for frame_raw in frames_raw:
				var result = _load_frame(frame_raw)
				if result.has("error"):
					return result
				sf.add_frame(anim_name, result["texture"], result["duration"])

		anim_info.append({
			"name": anim_name,
			"frame_count": sf.get_frame_count(anim_name),
			"fps": fps,
			"loop": loop,
		})

	# Remove the auto-created "default" animation when custom ones provided.
	if sf.has_animation("default") and anim_info.size() > 0:
		sf.remove_animation("default")

	var dir_path := file_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var save_err := ResourceSaver.save(sf, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save() returned error %d for %s" % [save_err, file_path])

	return MCPToolkitSuccess.ok({"path": file_path, "status": "created", "animations": anim_info})


static func _cmd_edit(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "action"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var action := str(parameters.get("action", ""))

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))

	if not FileAccess.file_exists(file_path):
		return MCPToolkitError.fail("NOT_FOUND", "SpriteFrames resource not found: %s" % file_path)

	var loaded = ResourceLoader.load(file_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded == null or not (loaded is SpriteFrames):
		return MCPToolkitError.fail("INVALID_CLASS",
			"Resource at %s is not a SpriteFrames" % file_path)
	var sf: SpriteFrames = loaded as SpriteFrames

	var anim_name := str(parameters.get("animation_name", ""))

	match action:
		"list":
			return _build_list(sf)

		"add_animation":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if sf.has_animation(anim_name):
				return MCPToolkitSuccess.ok({"action": action, "animation_name": anim_name, "status": "returned"})
			sf.add_animation(anim_name)
			var fps_raw = parameters.get("fps", null)
			if fps_raw != null:
				sf.set_animation_speed(anim_name, float(fps_raw))
			var loop_raw = parameters.get("loop", null)
			if loop_raw != null:
				sf.set_animation_loop(anim_name, bool(loop_raw))

		"remove_animation":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			sf.remove_animation(anim_name)

		"add_frame":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			var frames_raw = parameters.get("frames", null)
			if frames_raw == null or typeof(frames_raw) != TYPE_ARRAY or frames_raw.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "frames array is required for add_frame")
			for frame_raw in frames_raw:
				var result = _load_frame(frame_raw)
				if result.has("error"):
					return result
				sf.add_frame(anim_name, result["texture"], result["duration"])

		"remove_frame":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			var frame_index_raw = parameters.get("frame_index", null)
			if frame_index_raw == null:
				return MCPToolkitError.fail("INVALID_PARAMS", "frame_index is required for remove_frame")
			var idx := int(frame_index_raw)
			if idx < 0 or idx >= sf.get_frame_count(anim_name):
				return MCPToolkitError.fail("INVALID_PARAMS",
					"frame_index %d out of range (0..%d)" % [idx, sf.get_frame_count(anim_name) - 1])
			sf.remove_frame(anim_name, idx)

		"set_fps":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			var fps_val = parameters.get("fps", null)
			if fps_val == null:
				return MCPToolkitError.fail("INVALID_PARAMS", "fps is required for set_fps")
			sf.set_animation_speed(anim_name, float(fps_val))

		"set_loop":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			var loop_val = parameters.get("loop", null)
			if loop_val == null:
				return MCPToolkitError.fail("INVALID_PARAMS", "loop is required for set_loop")
			sf.set_animation_loop(anim_name, bool(loop_val))

		"reorder_frames":
			if anim_name.is_empty():
				return MCPToolkitError.fail("INVALID_PARAMS", "animation_name is required")
			if not sf.has_animation(anim_name):
				return MCPToolkitError.fail("NOT_FOUND", "Animation '%s' not found" % anim_name)
			var from_idx_raw = parameters.get("frame_index", null)
			var to_idx_raw = parameters.get("new_index", null)
			if from_idx_raw == null or to_idx_raw == null:
				return MCPToolkitError.fail("INVALID_PARAMS", "frame_index and new_index are required for reorder_frames")
			var from_idx := int(from_idx_raw)
			var to_idx := int(to_idx_raw)
			var count := sf.get_frame_count(anim_name)
			if from_idx < 0 or from_idx >= count or to_idx < 0 or to_idx >= count:
				return MCPToolkitError.fail("INVALID_PARAMS",
					"frame_index/new_index out of range (0..%d)" % [count - 1])
			var tex = sf.get_frame_texture(anim_name, from_idx)
			var dur := sf.get_frame_duration(anim_name, from_idx)
			sf.remove_frame(anim_name, from_idx)
			sf.add_frame(anim_name, tex, dur, to_idx)

		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"Unknown action '%s'. Expected: add_animation, remove_animation, add_frame, remove_frame, set_fps, set_loop, reorder_frames, list" % action)

	var save_err := ResourceSaver.save(sf, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save() returned error %d for %s" % [save_err, file_path])

	return MCPToolkitSuccess.ok({"action": action, "animation_name": anim_name})


static func _cmd_from_spritesheet(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["file_path", "texture_path", "frame_size", "animations"])
	if err != null:
		return err

	var file_path := str(parameters.get("file_path", ""))
	file_path = Helpers.normalize_editor_path(file_path)
	var texture_path := str(parameters.get("texture_path", ""))
	texture_path = Helpers.normalize_editor_path(texture_path)
	var frame_size_raw = parameters.get("frame_size", null)
	var animations_raw = parameters.get("animations", null)

	if typeof(frame_size_raw) != TYPE_DICTIONARY:
		return MCPToolkitError.fail("INVALID_PARAMS", "frame_size must be {x, y}")
	var frame_w := int(frame_size_raw.get("x", 0))
	var frame_h := int(frame_size_raw.get("y", 0))
	if frame_w <= 0 or frame_h <= 0:
		return MCPToolkitError.fail("INVALID_PARAMS", "frame_size x and y must be positive integers")

	if typeof(animations_raw) != TYPE_ARRAY or animations_raw.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "animations must be a non-empty Array")

	var guard := FileGuard.resolve_safe(file_path)
	if guard["error"] != null:
		return MCPToolkitError.fail("PATH_DENIED", str(guard["reason"]))
	if file_path.get_extension().to_lower() != "tres":
		return MCPToolkitError.fail("INVALID_PATH",
			"spriteframes.from_spritesheet writes .tres files (got %s)" % file_path)

	# Idempotency.
	if FileAccess.file_exists(file_path):
		return MCPToolkitSuccess.ok({"status": "returned", "path": file_path})

	if not ResourceLoader.exists(texture_path):
		return MCPToolkitError.fail("NOT_FOUND", "Spritesheet texture not found: %s" % texture_path)
	var sheet_tex = ResourceLoader.load(texture_path)
	if sheet_tex == null or not (sheet_tex is Texture2D):
		return MCPToolkitError.fail("NOT_FOUND", "Failed to load spritesheet texture: %s" % texture_path)

	var tex_size: Vector2 = sheet_tex.get_size()
	var cols := int(tex_size.x) / frame_w
	var rows := int(tex_size.y) / frame_h

	var sf := SpriteFrames.new()
	var anim_info := []

	for anim_raw in animations_raw:
		if typeof(anim_raw) != TYPE_DICTIONARY:
			return MCPToolkitError.fail("INVALID_PARAMS", "each animation must be a Dictionary")

		var anim_name := str(anim_raw.get("name", ""))
		if anim_name.is_empty():
			return MCPToolkitError.fail("INVALID_PARAMS", "animation name is required")

		var row := int(anim_raw.get("row", 0))
		var start_col := int(anim_raw.get("start_col", 0))
		var frame_count := int(anim_raw.get("frame_count", 0))
		if frame_count <= 0:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"frame_count must be positive for animation '%s'" % anim_name)

		if row < 0 or row >= rows:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"row %d out of bounds (texture has %d rows of %dpx)" % [row, rows, frame_h])
		if start_col < 0 or (start_col + frame_count) > cols:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"columns %d..%d out of bounds (texture has %d cols of %dpx)" % [
					start_col, start_col + frame_count - 1, cols, frame_w])

		var fps: float = float(anim_raw.get("fps", 5.0))
		var loop: bool = bool(anim_raw.get("loop", true))

		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, fps)
		sf.set_animation_loop(anim_name, loop)

		for col_idx in range(start_col, start_col + frame_count):
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet_tex
			atlas.region = Rect2(col_idx * frame_w, row * frame_h, frame_w, frame_h)
			sf.add_frame(anim_name, atlas)

		anim_info.append({
			"name": anim_name,
			"frame_count": frame_count,
			"fps": fps,
			"loop": loop,
		})

	if sf.has_animation("default") and anim_info.size() > 0:
		sf.remove_animation("default")

	var dir_path := file_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var save_err := ResourceSaver.save(sf, file_path)
	if save_err != OK:
		return MCPToolkitError.fail("SAVE_FAILED",
			"ResourceSaver.save() returned error %d for %s" % [save_err, file_path])

	return MCPToolkitSuccess.ok({"path": file_path, "status": "created", "animations": anim_info})


# -- Helpers ------------------------------------------------------------------


static func _load_frame(frame_raw) -> Dictionary:
	if typeof(frame_raw) != TYPE_DICTIONARY:
		return MCPToolkitError.fail("INVALID_PARAMS", "each frame must be a Dictionary")

	var texture_path := str(frame_raw.get("texture_path", ""))
	if texture_path.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "frame texture path is required")

	if not ResourceLoader.exists(texture_path):
		return MCPToolkitError.fail("NOT_FOUND", "Texture not found: %s" % texture_path)

	var tex = ResourceLoader.load(texture_path)
	if tex == null or not (tex is Texture2D):
		return MCPToolkitError.fail("NOT_FOUND", "Failed to load texture: %s" % texture_path)

	var atlas_raw = frame_raw.get("atlas", null)
	if atlas_raw != null and typeof(atlas_raw) == TYPE_DICTIONARY:
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(
			float(atlas_raw.get("x", 0)),
			float(atlas_raw.get("y", 0)),
			float(atlas_raw.get("width", 0)),
			float(atlas_raw.get("height", 0)))
		tex = atlas

	var duration: float = float(frame_raw.get("duration", 1.0))
	return {"texture": tex, "duration": duration}


static func _build_list(sf: SpriteFrames) -> Dictionary:
	var anims := []
	for anim_name in sf.get_animation_names():
		anims.append({
			"name": str(anim_name),
			"frame_count": sf.get_frame_count(anim_name),
			"fps": sf.get_animation_speed(anim_name),
			"loop": sf.get_animation_loop(anim_name),
		})
	return MCPToolkitSuccess.ok({"animations": anims})
