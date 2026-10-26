@tool
extends RefCounted
## Pins the transport's auth and open deadlines against a real loopback listener:
## the auth timeout counts from the poll that first sees a peer open, a frame that
## waited for a late poll still counts, a silent or wrong-token peer is closed once,
## and a peer that never opens is dropped. Drives accept_pending() and poll_peers()
## directly, as the owning servers' pump() does.

const Testing := preload("res://test/units/testing.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")
const RuntimeServer := preload("res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd")

const _TOKEN := "unit-test-token"
const _PORT_BASE := 18920
const _PORT_RANGE := 10
# Wide enough that a slow loopback handshake opens well inside it; each case
# sleeps twice this, so it sets the suite's cost.
const _AUTH_TIMEOUT_MS := 1000
# The never-opening client makes no handshake for this timeout to race, so its
# case runs on a short one: the open deadline is 5x the auth timeout.
const _NEVER_OPENS_AUTH_TIMEOUT_MS := 200
# A loopback socket progresses in real time, not in frames, so each wait on a
# socket state polls once a frame and gives up after this many milliseconds.
const _WAIT_CAP_MS := 3000
# Any 16-byte nonce, base64-encoded; the raw client ignores the accept key.
const _RAW_KEY := "dGhlIHNhbXBsZSBub25jZQ=="
const _OPCODE_TEXT := 0x1
const _OPCODE_CLOSE := 0x8


## [param tree] is the runner itself, whose frames the socket waits await.
static func run(testing: Testing, tree: SceneTree) -> void:
	await _test_auth_frame_read_on_a_late_poll(testing, tree)
	await _test_silent_peer_closed_after_timeout(testing, tree)
	await _test_auth_in_time(testing, tree)
	await _test_held_back_upgrade_gets_the_full_timeout(testing, tree)
	await _test_late_wrong_token_closed_once(testing, tree)
	await _test_late_malformed_frames_answered_before_the_close(testing, tree)
	await _test_never_opening_peer_dropped(testing, tree)
	await _test_reconnect_gets_fresh_deadlines(testing, tree)


# The owning server polls from its frame loop, and one long frame can outlast the
# timeout. A client that authenticated right away must not be closed because the
# poll that reads its frame came late.
static func _test_auth_frame_read_on_a_late_poll(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport authenticates a frame that waited for a late poll")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client, tree)

	client.send_text(JSON.stringify({"auth": _TOKEN}))
	client.poll()
	# The delay is the scenario: the server's next poll comes after the
	# timeout, with the auth frame already in its buffer.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	await transport.poll_peers()
	var authed_count := transport.get_authed_count()
	var ack: String = await _next_frame(transport, client, tree)
	var client_state := client.get_ready_state()

	client.close()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(opened, "the client's WebSocket opened against the loopback listener")
	testing.eq(authed_count, 1, "auth frame sent in time, read after the timeout → the peer is authed")
	testing.eq(ack, "{\"authed\":true}", "auth frame sent in time, read after the timeout → the client gets the auth ack")
	testing.eq(client_state, WebSocketPeer.STATE_OPEN, "auth frame sent in time, read after the timeout → the connection stays open")
	print("")


# The timeout still does its job: a client that never authenticates is closed.
static func _test_silent_peer_closed_after_timeout(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport closes a peer that never sends its auth frame")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client, tree)

	# The delay is the scenario: the client stays silent until the server's next
	# poll comes after the timeout.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	var closed: Array[WebSocketPeer] = await transport.poll_peers()
	var closed_count := closed.size()
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
		await transport.poll_peers()
		await tree.process_frame
	var close_code := client.get_close_code()
	var close_reason := client.get_close_reason()

	transport.cleanup(closed)
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(opened, "the client's WebSocket opened against the loopback listener")
	testing.eq(closed_count, 1, "no auth frame past the timeout → the server closes the peer")
	testing.eq(close_code, 1008, "no auth frame past the timeout → close code 1008")
	testing.eq(close_reason, "auth timeout", "no auth frame past the timeout → close reason 'auth timeout'")
	print("")


# The common path: a client that sends its auth frame as soon as it opens.
static func _test_auth_in_time(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport authenticates a client that sends its auth frame at once")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client, tree)

	client.send_text(JSON.stringify({"auth": _TOKEN}))
	client.poll()
	var ack: String = await _next_frame(transport, client, tree)
	var authed_count := transport.get_authed_count()
	var client_state := client.get_ready_state()

	client.close()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(opened, "the client's WebSocket opened against the loopback listener")
	testing.eq(ack, "{\"authed\":true}", "auth frame sent at once → the client gets the auth ack")
	testing.eq(authed_count, 1, "auth frame sent at once → the peer is authed")
	testing.eq(client_state, WebSocketPeer.STATE_OPEN, "auth frame sent at once → the connection stays open")
	print("")


# A client sends its upgrade request only when it polls, so a client stalled after
# its TCP connect opens late. Its auth timeout must start when its WebSocket opens:
# it cannot send an auth frame before it has seen the upgrade reply.
static func _test_held_back_upgrade_gets_the_full_timeout(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport counts the auth timeout from the open, not the TCP accept")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	# The delay is the scenario: the server accepts and keeps polling while the
	# unpolled client holds back its upgrade request past the auth timeout, and
	# inside the open deadline.
	var hold_until := Time.get_ticks_msec() + _AUTH_TIMEOUT_MS * 2
	while Time.get_ticks_msec() < hold_until:
		transport.accept_pending()
		await transport.poll_peers()
		await tree.process_frame
	var opened: bool = await _open(transport, client, tree)

	client.send_text(JSON.stringify({"auth": _TOKEN}))
	client.poll()
	var ack: String = await _next_frame(transport, client, tree)
	var authed_count := transport.get_authed_count()
	var client_state := client.get_ready_state()
	var close_reason := client.get_close_reason()

	client.close()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(opened, "upgrade held back past the auth timeout → the client's WebSocket opens")
	testing.eq(close_reason, "", "upgrade held back past the auth timeout → no 'auth timeout' close")
	testing.eq(ack, "{\"authed\":true}", "upgrade held back past the auth timeout → the client gets the auth ack")
	testing.eq(authed_count, 1, "upgrade held back past the auth timeout → the peer is authed")
	testing.eq(client_state, WebSocketPeer.STATE_OPEN, "upgrade held back past the auth timeout → the connection stays open")
	print("")


# A wrong token read on a late poll is closed by the token check. The auth timeout
# must leave that peer alone rather than close it a second time and report it
# closed before its close has completed.
static func _test_late_wrong_token_closed_once(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport closes a late wrong-token frame once, as invalid token")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client, tree)

	client.send_text(JSON.stringify({"auth": "not-the-token"}))
	client.poll()
	# The delay is the scenario: the server's next poll comes after the timeout,
	# with the wrong-token frame already in its buffer.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	var returned_count := 0
	var returned_after_close := true
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		var closed: Array[WebSocketPeer] = await transport.poll_peers()
		for peer: WebSocketPeer in closed:
			returned_count += 1
			returned_after_close = returned_after_close \
					and peer.get_ready_state() == WebSocketPeer.STATE_CLOSED
		transport.cleanup(closed)
		client.poll()
		if returned_count > 0 and client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
		await tree.process_frame
	var close_code := client.get_close_code()
	var close_reason := client.get_close_reason()

	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(opened, "the client's WebSocket opened against the loopback listener")
	testing.eq(close_code, 1008, "wrong token read after the timeout → close code 1008")
	testing.eq(close_reason, "invalid token", "wrong token read after the timeout → close reason 'invalid token'")
	testing.eq(returned_count, 1, "wrong token read after the timeout → poll_peers() returns the peer once")
	testing.ok(returned_after_close, "wrong token read after the timeout → the peer is returned once its close completes, not timed out on top")
	print("")


# Frames read on a late poll reach the server's handler before the auth timeout
# closes the peer, so a malformed one still gets its JSON-RPC error. A WebSocketPeer
# client drops the frames it has not read once a close frame arrives in the same
# poll, so a raw socket client reads the server's frames off the wire in order.
static func _test_late_malformed_frames_answered_before_the_close(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport answers late malformed frames, then closes on the timeout")
	var transport := _listening_transport()
	var server := RuntimeServer.new()
	# Seeded by hand: the runtime server wires its transport and handler in _ready,
	# which needs the game's port config and registry.
	server._transport = transport
	transport.set_handlers(server._handle_message, Callable(), Callable(), Callable())
	var client := StreamPeerTCP.new()
	var opened: bool = await _raw_open(transport, client, tree)

	_raw_send_text(client, "not json")
	_raw_send_text(client, "[1]")
	# The delay is the scenario: the server's next poll comes after the timeout,
	# with both frames already in its buffer.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	var frames: Array[Dictionary] = await _raw_frames_until_close(transport, client, tree)
	var received := _describe_frames(frames)

	client.disconnect_from_host()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()
	server.free()

	testing.ok(opened, "the raw client's upgrade got the 101 reply")
	testing.eq(received, ["error -32700", "error -32600", "close 1008 auth timeout"],
			"malformed frames read after the timeout → each gets its JSON-RPC error, then the 1008 'auth timeout' close")
	print("")


# A client that connects over TCP and never sends an upgrade request would hold a
# peer for good: the server side of the handshake has no deadline of its own.
static func _test_never_opening_peer_dropped(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport drops a peer that never opens, at the open deadline")
	var transport := _listening_transport(_NEVER_OPENS_AUTH_TIMEOUT_MS)
	var client := StreamPeerTCP.new()
	var connect_ms := Time.get_ticks_msec()
	client.connect_to_host("127.0.0.1", transport.get_bound_port())
	var returned_count := 0
	var dropped_after_ms := -1
	var deadline := connect_ms + _NEVER_OPENS_AUTH_TIMEOUT_MS * 5 + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline and returned_count == 0:
		client.poll()
		transport.accept_pending()
		var closed: Array[WebSocketPeer] = await transport.poll_peers()
		returned_count += closed.size()
		if not closed.is_empty():
			dropped_after_ms = Time.get_ticks_msec() - connect_ms
		transport.cleanup(closed)
		await tree.process_frame
	var tcp_deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < tcp_deadline:
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		await tree.process_frame
	var client_status := client.get_status()

	client.disconnect_from_host()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.eq(returned_count, 1, "no upgrade request → poll_peers() returns the peer once")
	testing.ok(dropped_after_ms >= _NEVER_OPENS_AUTH_TIMEOUT_MS * 5,
			"no upgrade request → the peer is dropped no sooner than 5x the auth timeout after the connect (%d ms)" % dropped_after_ms)
	testing.ok(client_status != StreamPeerTCP.STATUS_CONNECTED, "no upgrade request → the client's TCP connection is dropped")
	print("")


# A reconnect is a new peer: once every peer has been closed, a client that
# connects later gets its own deadlines, not ones left from the last connection.
static func _test_reconnect_gets_fresh_deadlines(testing: Testing, tree: SceneTree) -> void:
	testing.begin("ws transport gives a client that reconnects after a close fresh deadlines")
	var transport := _listening_transport()
	var first := WebSocketPeer.new()
	first.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var first_opened: bool = await _open(transport, first, tree)
	first.send_text(JSON.stringify({"auth": _TOKEN}))
	first.poll()
	var first_ack: String = await _next_frame(transport, first, tree)
	transport.close_all(1008, "token rotated")
	first.close()
	# The delay is the scenario: the reconnect comes after the first connection's
	# auth timeout would have run out.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)

	var second := WebSocketPeer.new()
	second.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var second_opened: bool = await _open(transport, second, tree)
	second.send_text(JSON.stringify({"auth": _TOKEN}))
	second.poll()
	var second_ack: String = await _next_frame(transport, second, tree)
	var authed_count := transport.get_authed_count()
	var second_state := second.get_ready_state()

	second.close()
	transport.close_all(1000, "test over")
	transport.shutdown_listener()

	testing.ok(first_opened and first_ack == "{\"authed\":true}", "the first client opened and authed")
	testing.ok(second_opened, "reconnect after a close → the client's WebSocket opens")
	testing.eq(second_ack, "{\"authed\":true}", "reconnect after a close → the client gets the auth ack")
	testing.eq(authed_count, 1, "reconnect after a close → the new peer is authed")
	testing.eq(second_state, WebSocketPeer.STATE_OPEN, "reconnect after a close → the connection stays open")
	print("")


## A transport bound to the first free port of the test band, whose message
## handler treats every frame as an auth frame.
static func _listening_transport(auth_timeout_ms: int = _AUTH_TIMEOUT_MS) -> WsTransport:
	var transport := WsTransport.new()
	transport.configure("[TestAuthTimeout]", _PORT_BASE, _PORT_RANGE, "127.0.0.1", 1,
			auth_timeout_ms, false, "no free port in %d-%d")
	var on_message := func(peer: WebSocketPeer, text: String) -> void:
		var message: Variant = JSON.parse_string(text)
		if message is Dictionary:
			transport.validate_auth(peer, message)
	transport.set_handlers(on_message, Callable(), Callable(), Callable())
	transport.set_token(_TOKEN)
	transport.ensure_listening()
	return transport


## Drives the server and [param client] once a frame until the client's WebSocket
## is open. Returns whether it opened within [constant _WAIT_CAP_MS].
static func _open(transport: WsTransport, client: WebSocketPeer, tree: SceneTree) -> bool:
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		transport.accept_pending()
		await transport.poll_peers()
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return true
		await tree.process_frame
	return false


## Polls both ends once a frame until [param client] receives a frame, and returns
## its text, or "" when none arrives within [constant _WAIT_CAP_MS].
static func _next_frame(transport: WsTransport, client: WebSocketPeer, tree: SceneTree) -> String:
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		await transport.poll_peers()
		client.poll()
		if client.get_available_packet_count() > 0:
			return client.get_packet().get_string_from_utf8()
		await tree.process_frame
	return ""


## Connects [param client] to the transport and sends a WebSocket upgrade request
## by hand, polling both ends once a frame. Returns whether the 101 reply arrived
## within [constant _WAIT_CAP_MS].
static func _raw_open(transport: WsTransport, client: StreamPeerTCP, tree: SceneTree) -> bool:
	client.connect_to_host("127.0.0.1", transport.get_bound_port())
	var request := ("GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
			+ "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % [
			transport.get_bound_port(), _RAW_KEY]
	var sent := false
	var reply := ""
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		client.poll()
		transport.accept_pending()
		await transport.poll_peers()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				client.put_data(request.to_utf8_buffer())
				sent = true
			var available := client.get_available_bytes()
			if available > 0:
				reply += client.get_utf8_string(available)
			if reply.contains("\r\n\r\n"):
				return reply.begins_with("HTTP/1.1 101")
		await tree.process_frame
	return false


## Sends [param text] as one masked text frame, as a client must; the zero mask
## leaves the payload as is. Payloads stay under 126 bytes.
static func _raw_send_text(client: StreamPeerTCP, text: String) -> void:
	var payload := text.to_utf8_buffer()
	var frame := PackedByteArray([0x80 | _OPCODE_TEXT, 0x80 | payload.size(), 0, 0, 0, 0])
	frame.append_array(payload)
	client.put_data(frame)


## Reads the server's frames from [param client], polling both ends once a frame,
## until a close frame arrives or [constant _WAIT_CAP_MS] passes. Returns each frame
## as {"opcode": int, "payload": PackedByteArray}, in arrival order.
static func _raw_frames_until_close(transport: WsTransport, client: StreamPeerTCP,
		tree: SceneTree) -> Array[Dictionary]:
	var frames: Array[Dictionary] = []
	var buffer := PackedByteArray()
	var deadline := Time.get_ticks_msec() + _WAIT_CAP_MS
	while Time.get_ticks_msec() < deadline:
		await transport.poll_peers()
		client.poll()
		var available := client.get_available_bytes()
		if available > 0:
			var read: Array = client.get_partial_data(available)
			var bytes: PackedByteArray = read[1]
			buffer.append_array(bytes)
		while buffer.size() >= 2:
			var header_size := 2
			var length: int = buffer[1] & 0x7F
			if length == 126:
				if buffer.size() < 4:
					break
				header_size = 4
				length = (buffer[2] << 8) | buffer[3]
			if buffer.size() < header_size + length:
				break
			var opcode: int = buffer[0] & 0x0F
			frames.append({"opcode": opcode, "payload": buffer.slice(header_size, header_size + length)})
			buffer = buffer.slice(header_size + length)
			if opcode == _OPCODE_CLOSE:
				return frames
		await tree.process_frame
	return frames


## Names each frame from [method _raw_frames_until_close]: "error <code>" for a
## JSON-RPC error, "close <code> <reason>" for a close, "opcode <n>" otherwise.
static func _describe_frames(frames: Array[Dictionary]) -> Array:
	var described := []
	for frame: Dictionary in frames:
		var opcode: int = frame["opcode"]
		var payload: PackedByteArray = frame["payload"]
		if opcode == _OPCODE_TEXT:
			var reply: Variant = JSON.parse_string(payload.get_string_from_utf8())
			var error: Variant = (reply as Dictionary).get("error") if reply is Dictionary else null
			if error is Dictionary:
				described.append("error %d" % int((error as Dictionary).get("code", 0)))
			else:
				described.append("text %s" % payload.get_string_from_utf8())
		elif opcode == _OPCODE_CLOSE and payload.size() >= 2:
			var code := (payload[0] << 8) | payload[1]
			described.append("close %d %s" % [code, payload.slice(2).get_string_from_utf8()])
		else:
			described.append("opcode %d" % opcode)
	return described
