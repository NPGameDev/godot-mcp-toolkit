@tool
extends Node
## WebSocket JSON-RPC framing and peer lifecycle.

const _Hub := preload("res://addons/godot_mcp_toolkit/_hub.gd")
const MCPCommandRegistry = _Hub.MCPCommandRegistry
const MCPAuth := preload("res://addons/godot_mcp_toolkit/auth.gd")
##
## All command logic lives in per-domain modules under commands/.
## This file handles: TCP listener, WS peer accept/poll, JSON-RPC parse,
## dispatch via MCPCommandRegistry, and UndoRedo helper methods referenced
## by name from command handlers.

const PORT := 6505
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"
# iter 13: throttle re-listen retries to avoid log spam when the port is
# briefly held by another process (e.g. a second editor instance, a stale
# debugger). 60 frames ≈ 1s at 60fps; the bridge's reconnect backoff sits
# on the same order so we don't pile retries on top of the bridge's.
const _RELISTEN_FRAME_INTERVAL := 60
# iter 13c: poll TCPServer/WebSocket peers every Nth frame instead of every
# frame. Godot 4.4.1 has a race between our per-frame poll and the main-loop
# work triggered by FileSystem-dock interactions; shrinking our collision
# window ~4x (15Hz vs 60Hz) drops the reproducibility threshold enough that
# incidental clicks stop crashing the editor in smoke + dogfood usage.
# Tune lower if latency regresses noticeably; 4 frames ≈ 67ms at 60fps.
const _POLL_FRAME_INTERVAL := 4
# iter 18: auth timeout. Peers that don't send a valid auth message
# within this window are closed with WS close code 1008 (Policy Violation).
const _AUTH_TIMEOUT_MS := 2000

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _relisten_countdown := 0
# Tracks the current run of consecutive _try_listen() failures so we can log
# the first one (with a hint), stay silent during retries, and announce the
# recovery with the attempt count. Reset on every successful listen.
var _consecutive_failures := 0
# iter 13c: counter for _POLL_FRAME_INTERVAL frame-skip.
var _poll_frame_counter := 0
# iter 15e: captured at start() so editor.get_console's log-file selection
# heuristic can prefer post-boot logs over stale rotated ones.
var _plugin_boot_time: int = 0
# iter 16: registry-based dispatch — populated by plugin.gd before start().
var _registry: MCPCommandRegistry = null
# iter 18: session token + per-peer auth tracking.
var _session_token: String = ""
var _peer_authed: Dictionary = {}       # WebSocketPeer -> true (authed peers only)
var _peer_connect_ms: Dictionary = {}   # WebSocketPeer -> int (ticks_msec at accept)


func set_registry(registry: MCPCommandRegistry) -> void:
	_registry = registry


func start() -> void:
	_plugin_boot_time = int(Time.get_unix_time_from_system())
	_relisten_countdown = 0
	# iter 18: rotate token each editor session.
	_session_token = MCPAuth.generate_token()
	var write_err := MCPAuth.write_token(_session_token)
	if write_err != OK:
		push_warning("[MCPServer] failed to write token (err %d); auth will still be enforced but bridge may not find the file" % write_err)
	else:
		var token_path := MCPAuth.get_token_path()
		print("[MCPServer] session token written to %s" % token_path)
	_try_listen()


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	_peer_authed.clear()
	_peer_connect_ms.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	print("[MCPServer] stopped")


# iter 13: idempotent re-listen. Called from start() and from _process when
# the TCPServer falls out of the listening state (port stolen, manual stop,
# etc.). Frame-throttled via _relisten_countdown so failures don't spam.
func _try_listen() -> void:
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var error := _tcp_server.listen(PORT, BIND)
	if error == OK:
		if _consecutive_failures > 0:
			print("[MCPServer] listening on %s:%d (recovered after %d failed attempts)" % [BIND, PORT, _consecutive_failures])
		else:
			print("[MCPServer] listening on %s:%d" % [BIND, PORT])
		_consecutive_failures = 0
		_relisten_countdown = 0
		return
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		var hint := ""
		if error == ERR_ALREADY_IN_USE:
			hint = " (ERR_ALREADY_IN_USE — likely a stale Godot/MCP process holding the port; will retry silently every ~1s, watch for the listening / recovered message)"
		push_warning("[MCPServer] bind %s:%d failed (err %d)%s" % [BIND, PORT, error, hint])
	# Discard the (potentially-stuck) TCPServer instance so the next retry
	# allocates a fresh one. Without this, certain Godot-internal latch
	# states keep returning ERR_ALREADY_IN_USE even after the actual port
	# is freed.
	_tcp_server.stop()
	_tcp_server = null
	_relisten_countdown = _RELISTEN_FRAME_INTERVAL


func _process(_delta: float) -> void:
	_poll_frame_counter += 1
	if _poll_frame_counter < _POLL_FRAME_INTERVAL:
		return
	_poll_frame_counter = 0

	if _tcp_server == null or not _tcp_server.is_listening():
		_try_listen()
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		# 1 MB buffers — script.write payloads can reach the 256 KB response
		# cap, and JSON-RPC framing adds overhead on top of content size.
		peer.inbound_buffer_size = 1048576
		peer.outbound_buffer_size = 1048576
		var accept_error := peer.accept_stream(stream)
		if accept_error != OK:
			push_warning("[MCPServer] accept_stream failed (%d)" % accept_error)
			continue
		_peers.append(peer)
		_peer_connect_ms[peer] = Time.get_ticks_msec()

	var closed_peers: Array[WebSocketPeer] = []
	var now_ms := Time.get_ticks_msec()
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		# iter 18: auth timeout — close peers that haven't authed in time.
		if not _peer_authed.has(peer):
			if now_ms - int(_peer_connect_ms.get(peer, 0)) > _AUTH_TIMEOUT_MS:
				peer.close(1008, "auth timeout")
				closed_peers.append(peer)
				continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			_handle_message(peer, text)

	for peer in closed_peers:
		_peers.erase(peer)
		_peer_authed.erase(peer)
		_peer_connect_ms.erase(peer)


func _handle_message(peer: WebSocketPeer, text: String) -> void:
	var parser := JSON.new()
	var parse_error := parser.parse(text)
	if parse_error != OK:
		_send_error(peer, null, -32700, "Parse error: %s" % parser.get_error_message())
		return

	var message = parser.data
	if typeof(message) != TYPE_DICTIONARY:
		_send_error(peer, null, -32600, "Invalid Request: top-level must be an object")
		return

	# iter 18: auth handshake — first message must be {"auth": "<token>"}.
	if not _peer_authed.has(peer):
		if MCPAuth.validate(message, _session_token):
			_peer_authed[peer] = true
			peer.send_text(JSON.stringify({"authed": true}))
		else:
			peer.close(1008, "invalid token")
		return

	var id = message.get("id", null)
	# Godot's JSON parser returns every number as float; coerce whole-float ids
	# back to int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(message.get("method", ""))
	var parameters = message.get("params", null)

	if method.is_empty():
		_send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	# echo is a transport-level diagnostic, not a domain command.
	if method == "echo":
		_send_result(peer, id, parameters)
		return

	if _registry == null or not _registry.has_command(method):
		_send_error(peer, id, -32601, "Method not found: %s" % method)
		return

	var safe_parameters: Dictionary = parameters \
		if typeof(parameters) == TYPE_DICTIONARY else {}
	var result: Dictionary = _registry.call_command(method, safe_parameters)
	_send_result(peer, id, result)


func _send_result(peer: WebSocketPeer, id, result) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	peer.send_text(JSON.stringify(response))


func _send_error(peer: WebSocketPeer, id, code: int, error_message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": error_message,
		},
	}
	peer.send_text(JSON.stringify(response))


# -- UndoRedo helper methods ---------------------------------------------------
#
# These are referenced by STRING NAME from domain command files via
# EditorUndoRedoManager.add_do_method / add_undo_method. They must live on
# this Node so UndoRedo can call them. Do not move to static helpers.


func _write_file_silent(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[MCPServer] UndoRedo write of %s failed (err %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string(content)
	file.close()


func _delete_file_silent(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var error := DirAccess.remove_absolute(path)
	if error != OK:
		push_warning("[MCPServer] UndoRedo delete of %s failed (err %d)" % [path, error])


func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.set_owner(owner)
	for child in node.get_children():
		_set_owner_recursive(child, owner)


func _animation_remove_key_at(animation: Animation, track_index: int, time: float) -> void:
	var key_index := animation.track_find_key(track_index, time, Animation.FIND_MODE_EXACT)
	if key_index != -1:
		animation.track_remove_key(track_index, key_index)


func _animation_insert_key_silent(animation: Animation, track_index: int, time: float, value) -> void:
	animation.track_insert_key(track_index, time, value)


func _tilemap_apply_batch(node: Node, layer: int, cells: Array) -> void:
	var is_layer := node is TileMapLayer
	for cell in cells:
		var coord := Vector2i(int(cell["x"]), int(cell["y"]))
		var source_id := int(cell["source_id"])
		var atlas := Vector2i(int(cell["atlas_x"]), int(cell["atlas_y"]))
		var alternative := int(cell.get("alternative_tile", 0))
		if is_layer:
			(node as TileMapLayer).set_cell(coord, source_id, atlas, alternative)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alternative)


func _tilemap_restore_batch(node: Node, layer: int, before_state: Array) -> void:
	var is_layer := node is TileMapLayer
	for state in before_state:
		var coord: Vector2i = state["coord"]
		var source_id := int(state["source_id"])
		var atlas: Vector2i = state["atlas"]
		var alternative := int(state["alternative_tile"])
		if is_layer:
			(node as TileMapLayer).set_cell(coord, source_id, atlas, alternative)
		else:
			(node as TileMap).set_cell(layer, coord, source_id, atlas, alternative)
