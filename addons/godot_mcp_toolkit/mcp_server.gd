@tool
extends Node

const PORT := 6505
const BIND := "127.0.0.1"
const JSONRPC_VERSION := "2.0"

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []


func start() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, BIND)
	if err != OK:
		push_error("[MCPServer] failed to bind %s:%d (error %d)" % [BIND, PORT, err])
		_tcp_server = null
		return
	print("[MCPServer] listening on %s:%d" % [BIND, PORT])


func stop() -> void:
	for peer in _peers:
		if peer != null:
			peer.close(1000)
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	print("[MCPServer] stopped")


func _process(_delta: float) -> void:
	if _tcp_server == null:
		return

	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var accept_err := peer.accept_stream(stream)
		if accept_err != OK:
			push_warning("[MCPServer] accept_stream failed (%d)" % accept_err)
			continue
		_peers.append(peer)

	var closed_peers: Array[WebSocketPeer] = []
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed_peers.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			_handle_message(peer, text)

	for peer in closed_peers:
		_peers.erase(peer)


func _handle_message(peer: WebSocketPeer, text: String) -> void:
	var parser := JSON.new()
	var parse_err := parser.parse(text)
	if parse_err != OK:
		_send_error(peer, null, -32700, "Parse error: %s" % parser.get_error_message())
		return

	var msg = parser.data
	if typeof(msg) != TYPE_DICTIONARY:
		_send_error(peer, null, -32600, "Invalid Request: top-level must be an object")
		return

	var id = msg.get("id", null)
	# Godot's JSON parser returns every number as float; coerce whole-float ids
	# back to int so {"id": 1} round-trips as {"id": 1}, not {"id": 1.0}.
	if typeof(id) == TYPE_FLOAT and int(id) == id:
		id = int(id)
	var method := str(msg.get("method", ""))
	var params = msg.get("params", null)

	if method.is_empty():
		_send_error(peer, id, -32600, "Invalid Request: missing method")
		return

	match method:
		"echo":
			_send_result(peer, id, params)
		_:
			_send_error(peer, id, -32601, "Method not found: %s" % method)


func _send_result(peer: WebSocketPeer, id, result) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"result": result,
	}
	peer.send_text(JSON.stringify(response))


func _send_error(peer: WebSocketPeer, id, code: int, message: String) -> void:
	var response := {
		"jsonrpc": JSONRPC_VERSION,
		"id": id,
		"error": {
			"code": code,
			"message": message,
		},
	}
	peer.send_text(JSON.stringify(response))
