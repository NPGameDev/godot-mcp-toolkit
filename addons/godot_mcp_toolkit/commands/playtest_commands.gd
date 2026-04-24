@tool
extends RefCounted
## game.* command handlers — start/stop editor playtest (Mode A).

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPError = _Hub.MCPError
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPFileGuard = _Hub.MCPFileGuard
const MCPRegistryClient = _Hub.MCPRegistryClient

const RUNTIME_HOST := "127.0.0.1"
const RUNTIME_POLL_TIMEOUT_MS := 5000
const _REGISTRY_POLL_INTERVAL_MS := 100


static func register(registry: MCPCommandRegistry, _server: Node) -> void:
	registry.add("game.start", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_start(parameters))
	registry.add("game.stop", func(parameters: Dictionary) -> Dictionary:
		return _cmd_game_stop(parameters))


# -- Commands -----------------------------------------------------------------


static func _cmd_game_start(parameters: Dictionary) -> Dictionary:
	var target := str(parameters.get("scene_path", "current"))
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
			var guard := MCPFileGuard.resolve_safe(target)
			if guard["error"] != null:
				return MCPError.make("PATH_DENIED", str(guard["reason"]))
			if target.get_extension().to_lower() != "tscn":
				return MCPError.make("INVALID_PATH",
					"game.start only plays .tscn files (got %s)" % target)
			if not FileAccess.file_exists(target):
				return MCPError.make("NOT_FOUND",
					"no scene file at %s; use scene.create first" % target, MCPError.HINT_FILE_PATH)
			EditorInterface.play_custom_scene(target)

	# Two-phase wait — poll registry for the runtime_port to appear (the
	# runtime server writes it after binding), then TCP-probe it.
	var runtime_port := -1
	var runtime_ready := false
	if wait_for_runtime:
		var deadline := Time.get_ticks_msec() + RUNTIME_POLL_TIMEOUT_MS
		while Time.get_ticks_msec() < deadline:
			runtime_port = MCPRegistryClient.get_runtime_port()
			if runtime_port > 0:
				break
			OS.delay_msec(_REGISTRY_POLL_INTERVAL_MS)
		if runtime_port > 0:
			var remaining := maxi(500, deadline - Time.get_ticks_msec())
			runtime_ready = _poll_runtime_ready(
				RUNTIME_HOST, runtime_port, remaining)

	var response := {
		"success": true,
		"target": target,
		"runtime_port": runtime_port if runtime_port > 0 else null,
		"runtime_ready": runtime_ready,
	}
	if wait_for_runtime and not runtime_ready:
		response["hint"] = "Runtime not ready. Checklist: (1) Is the MCP Runtime autoload enabled? Re-enable the plugin in Project Settings > Plugins if missing. (2) Is port 6525 available? (3) Check editor_get_console for runtime startup errors. (4) For Standard profile: call enable_tool_group(['runtime']) to load runtime tools."
	return response


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
