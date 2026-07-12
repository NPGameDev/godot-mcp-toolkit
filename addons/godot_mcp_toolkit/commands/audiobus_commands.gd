@tool
extends RefCounted
## audiobus.* command handlers — audio bus layout management.
##
## The published prefix is `audiobus.*` (audio-BUS routing: buses, sends,
## effects), deliberately distinct from `sound.*` (audio sample generation).
## A file noun of "audio" alone would blur the two — name by the bus concept.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const FileGuard = Modules.FileGuard
const Helpers = Modules.CommandHelpers
const Untrusted = Modules.Untrusted


static func register(registry: MCPToolkitCommandRegistry, _server: Node) -> void:
	registry.add("audiobus.edit", func(parameters: Dictionary) -> Dictionary:
		return _cmd_audiobus_edit(parameters)
	, MCPToolkitCommandOptions.new().mark_scene_independent())
	registry.add("audiobus.list", func(_parameters: Dictionary) -> Dictionary:
		return _action_list()
	, MCPToolkitCommandOptions.new().mark_scene_independent().mark_read_only())


# -- Commands -----------------------------------------------------------------


static func _cmd_audiobus_edit(parameters: Dictionary) -> Dictionary:
	var err = MCPToolkitError.require(parameters, ["action"])
	if err != null:
		return err

	var action := str(parameters.get("action", ""))

	match action:
		"add_bus":
			return _action_add_bus(parameters)
		"remove_bus":
			return _action_remove_bus(parameters)
		"set_bus":
			return _action_set_bus(parameters)
		"add_effect":
			return _action_add_effect(parameters)
		"remove_effect":
			return _action_remove_effect(parameters)
		_:
			return MCPToolkitError.fail("INVALID_PARAMS",
				"Unknown action '%s'; expected add_bus, remove_bus, set_bus, add_effect, or remove_effect" % action)


# -- Actions ------------------------------------------------------------------


static func _action_add_bus(parameters: Dictionary) -> Dictionary:
	var bus_name := str(parameters.get("bus_name", ""))
	if bus_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "bus_name is required for add_bus")

	# Check if bus already exists.
	if _find_bus_index(bus_name) >= 0:
		return MCPToolkitSuccess.ok({"status": "returned", "action": "add_bus",
			"bus_name": bus_name, "bus_count": AudioServer.bus_count})

	AudioServer.add_bus()
	var new_idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(new_idx, bus_name)

	var send_to := str(parameters.get("send_to", ""))
	if not send_to.is_empty():
		var send_idx := _find_bus_index(send_to)
		if send_idx < 0:
			# Remove the bus we just added — send target doesn't exist.
			AudioServer.remove_bus(new_idx)
			return MCPToolkitError.fail("NOT_FOUND", "send_to bus '%s' not found" % send_to)
		AudioServer.set_bus_send(new_idx, send_to)

	_save_bus_layout()
	return MCPToolkitSuccess.ok({"status": "created", "action": "add_bus",
		"bus_name": bus_name, "bus_count": AudioServer.bus_count})


static func _action_remove_bus(parameters: Dictionary) -> Dictionary:
	var idx := _resolve_bus_index(parameters)
	if idx == -2:
		return MCPToolkitError.fail("INVALID_PARAMS", "bus_name or bus_index is required for remove_bus")
	if idx < 0:
		return MCPToolkitError.fail("NOT_FOUND",
			"Bus '%s' not found" % str(parameters.get("bus_name", parameters.get("bus_index", ""))))

	if idx == 0:
		return MCPToolkitError.fail("INVALID_PARAMS", "Cannot remove the Master bus")

	var removed_name := AudioServer.get_bus_name(idx)
	AudioServer.remove_bus(idx)
	_save_bus_layout()
	return MCPToolkitSuccess.ok({"action": "remove_bus",
		"bus_name": removed_name, "bus_count": AudioServer.bus_count})


static func _action_set_bus(parameters: Dictionary) -> Dictionary:
	var idx := _resolve_bus_index(parameters)
	if idx == -2:
		return MCPToolkitError.fail("INVALID_PARAMS", "bus_name or bus_index is required for set_bus")
	if idx < 0:
		return MCPToolkitError.fail("NOT_FOUND",
			"Bus '%s' not found" % str(parameters.get("bus_name", parameters.get("bus_index", ""))))

	if parameters.has("volume_db"):
		AudioServer.set_bus_volume_db(idx, float(parameters["volume_db"]))
	if parameters.has("solo"):
		AudioServer.set_bus_solo(idx, bool(parameters["solo"]))
	if parameters.has("mute"):
		AudioServer.set_bus_mute(idx, bool(parameters["mute"]))
	if parameters.has("send_to"):
		var send_to := str(parameters["send_to"])
		if not send_to.is_empty():
			var send_idx := _find_bus_index(send_to)
			if send_idx < 0:
				return MCPToolkitError.fail("NOT_FOUND", "send_to bus '%s' not found" % send_to)
		AudioServer.set_bus_send(idx, send_to)

	_save_bus_layout()
	return MCPToolkitSuccess.ok({"action": "set_bus",
		"bus_name": AudioServer.get_bus_name(idx), "bus_count": AudioServer.bus_count})


static func _action_add_effect(parameters: Dictionary) -> Dictionary:
	var idx := _resolve_bus_index(parameters)
	if idx == -2:
		return MCPToolkitError.fail("INVALID_PARAMS", "bus_name or bus_index is required for add_effect")
	if idx < 0:
		return MCPToolkitError.fail("NOT_FOUND",
			"Bus '%s' not found" % str(parameters.get("bus_name", parameters.get("bus_index", ""))))

	var effect_dict = parameters.get("effect", null)
	if typeof(effect_dict) != TYPE_DICTIONARY:
		return MCPToolkitError.fail("INVALID_PARAMS", "effect object is required for add_effect")

	var type_name := str(effect_dict.get("type", ""))
	if type_name.is_empty():
		return MCPToolkitError.fail("INVALID_PARAMS", "effect.type is required")

	var effect := _create_effect(type_name)
	if effect == null:
		return MCPToolkitError.fail("INVALID_PARAMS",
			"Unknown effect type '%s'; use full class name (AudioEffectReverb) or suffix (Reverb). Valid: Reverb, Delay, Chorus, Compressor, Distortion, EQ6/10/21, LowPassFilter, HighPassFilter, BandPassFilter, Limiter, Panner, Phaser, PitchShift, Amplify" % type_name)

	# Apply effect-specific properties if provided.
	var properties = effect_dict.get("properties", null)
	if properties != null and typeof(properties) == TYPE_DICTIONARY:
		for key in properties:
			if effect.has_method("set"):
				effect.set(key, properties[key])

	var at_index := int(effect_dict.get("index", -1))
	if at_index < 0:
		at_index = AudioServer.get_bus_effect_count(idx)
	AudioServer.add_bus_effect(idx, effect, at_index)

	var enabled = effect_dict.get("enabled", null)
	if enabled != null:
		AudioServer.set_bus_effect_enabled(idx, at_index, bool(enabled))

	_save_bus_layout()
	return MCPToolkitSuccess.ok({"action": "add_effect",
		"bus_name": AudioServer.get_bus_name(idx),
		"effect_type": effect.get_class(),
		"effect_index": at_index,
		"bus_count": AudioServer.bus_count})


static func _action_remove_effect(parameters: Dictionary) -> Dictionary:
	var idx := _resolve_bus_index(parameters)
	if idx == -2:
		return MCPToolkitError.fail("INVALID_PARAMS", "bus_name or bus_index is required for remove_effect")
	if idx < 0:
		return MCPToolkitError.fail("NOT_FOUND",
			"Bus '%s' not found" % str(parameters.get("bus_name", parameters.get("bus_index", ""))))

	var effect_dict = parameters.get("effect", null)
	if typeof(effect_dict) != TYPE_DICTIONARY:
		return MCPToolkitError.fail("INVALID_PARAMS", "effect object with index is required for remove_effect")

	var effect_index = effect_dict.get("index", null)
	if effect_index == null:
		return MCPToolkitError.fail("INVALID_PARAMS", "effect.index is required for remove_effect")

	var ei := int(effect_index)
	if ei < 0 or ei >= AudioServer.get_bus_effect_count(idx):
		return MCPToolkitError.fail("INVALID_PARAMS",
			"effect index %d out of range (bus has %d effects)" % [ei, AudioServer.get_bus_effect_count(idx)])

	AudioServer.remove_bus_effect(idx, ei)
	_save_bus_layout()
	return MCPToolkitSuccess.ok({"action": "remove_effect",
		"bus_name": AudioServer.get_bus_name(idx),
		"effect_index": ei,
		"bus_count": AudioServer.bus_count})


static func _action_list() -> Dictionary:
	var buses := []
	for i in range(AudioServer.bus_count):
		var effects := []
		for j in range(AudioServer.get_bus_effect_count(i)):
			var effect := AudioServer.get_bus_effect(i, j)
			effects.append({
				"type": effect.get_class() if effect != null else "null",
				"enabled": AudioServer.is_bus_effect_enabled(i, j),
				"index": j,
			})
		buses.append({
			"name": AudioServer.get_bus_name(i),
			"index": i,
			"send": AudioServer.get_bus_send(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"solo": AudioServer.is_bus_solo(i),
			"mute": AudioServer.is_bus_mute(i),
			"effects": effects,
		})
	return MCPToolkitSuccess.ok({
		"bus_count": AudioServer.bus_count,
		"buses": Untrusted.wrap("audiobus", "project-audio", JSON.stringify(buses)),
	})


# -- Helpers ------------------------------------------------------------------


static func _find_bus_index(bus_name: String) -> int:
	for i in range(AudioServer.bus_count):
		if AudioServer.get_bus_name(i) == bus_name:
			return i
	return -1


## Resolve bus by name or index from parameters.
## Returns -2 if neither bus_name nor bus_index is provided.
## Returns -1 if not found.
static func _resolve_bus_index(parameters: Dictionary) -> int:
	if parameters.has("bus_name") and not str(parameters["bus_name"]).is_empty():
		return _find_bus_index(str(parameters["bus_name"]))
	if parameters.has("bus_index"):
		var bi := int(parameters["bus_index"])
		if bi >= 0 and bi < AudioServer.bus_count:
			return bi
		return -1
	return -2


static func _create_effect(type_name: String) -> AudioEffect:
	# Accept both full class names ("AudioEffectReverb") and suffixes ("Reverb").
	var class_name_str := type_name
	if not ClassDB.class_exists(class_name_str):
		class_name_str = "AudioEffect" + type_name
	if not ClassDB.class_exists(class_name_str):
		return null
	if not ClassDB.is_parent_class(class_name_str, "AudioEffect"):
		return null
	return ClassDB.instantiate(class_name_str) as AudioEffect


static func _save_bus_layout() -> void:
	var layout := AudioServer.generate_bus_layout()
	ResourceSaver.save(layout, "res://default_bus_layout.tres")
