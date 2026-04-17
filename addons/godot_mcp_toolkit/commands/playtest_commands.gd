@tool
extends RefCounted
class_name PlaytestCommands
## game.* command handlers — start/stop editor playtest (Mode A).

const RUNTIME_PORT := 9090
const RUNTIME_HOST := "127.0.0.1"
const RUNTIME_POLL_TIMEOUT_MS := 5000


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("game.start", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_start(parameters), "full")
	registry.add("game.stop", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_stop(parameters), "full")


# -- Commands -----------------------------------------------------------------


static func _cmd_game_start(parameters: Dictionary) -> Dictionary:
	var target := str(parameters.get("target", "current"))
	var wait_for_runtime_raw = parameters.get("wait_for_runtime", true)
	var wait_for_runtime := bool(wait_for_runtime_raw) \
		if typeof(wait_for_runtime_raw) == TYPE_BOOL else true

	if EditorInterface.is_playing_scene():
		return MCPError.make("ALREADY_PLAYING",
			"a game is already running; call game.stop first")

	match target:
		"main":
			EditorInterface.play_main_scene()
		"current":
			if EditorInterface.get_edited_scene_root() == null:
				return MCPError.make("NO_SCENE",
					"no currently-edited scene; use target:'main' or target:<res://path>, or scene.open first")
			EditorInterface.play_current_scene()
		_:
			# TODO(iter-18): route target through FileGuard.resolve_safe.
			if not target.begins_with("res://"):
				return MCPError.make("INVALID_PARAMS",
					"target must be 'main' | 'current' | a res:// scene path (got %s)" % target)
			if target.get_extension().to_lower() != "tscn":
				return MCPError.make("INVALID_PATH",
					"game.start only plays .tscn files (got %s)" % target)
			if not FileAccess.file_exists(target):
				return MCPError.make("NOT_FOUND",
					"no scene file at %s; use scene.create first" % target)
			EditorInterface.play_custom_scene(target)

	var runtime_ready := false
	if wait_for_runtime:
		runtime_ready = _poll_runtime_ready(
			RUNTIME_HOST, RUNTIME_PORT, RUNTIME_POLL_TIMEOUT_MS)

	return {
		"success": true,
		"target": target,
		"runtime_port": RUNTIME_PORT,
		"runtime_ready": runtime_ready,
	}


static func _cmd_game_stop(_parameters: Dictionary) -> Dictionary:
	var was_running := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return {"success": true, "was_running": was_running}


# -- Runtime probe ------------------------------------------------------------


static func _poll_runtime_ready(
	host: String, port: int, timeout_ms: int,
) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var stream := StreamPeerTCP.new()
		if stream.connect_to_host(host, port) == OK:
			var inner_deadline := Time.get_ticks_msec() + 150
			while Time.get_ticks_msec() < inner_deadline:
				stream.poll()
				var status := stream.get_status()
				if status == StreamPeerTCP.STATUS_CONNECTED:
					stream.disconnect_from_host()
					return true
				if status == StreamPeerTCP.STATUS_ERROR \
						or status == StreamPeerTCP.STATUS_NONE:
					break
				OS.delay_msec(10)
			stream.disconnect_from_host()
		OS.delay_msec(100)
	return false
