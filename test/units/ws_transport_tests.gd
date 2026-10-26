@tool
extends RefCounted
## Pins the transport's auth timeout against a real loopback listener and client:
## a peer that sent its auth frame in time is authed even when the next poll comes
## after the timeout, and a peer that sends nothing is closed with 1008. Drives
## accept_pending() and poll_peers() directly, as the owning servers' pump() does.

const Testing := preload("res://test/units/testing.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")

const _TOKEN := "unit-test-token"
const _PORT_BASE := 18920
const _PORT_RANGE := 10
# Short, so the late poll costs the suite well under a second.
const _AUTH_TIMEOUT_MS := 200
# A loopback socket progresses in real time, not in frames, so each wait on a
# socket state polls in short real-time steps and gives up after this many.
const _HANDSHAKE_STEPS := 200
const _STEP_MSEC := 5


static func run(testing: Testing) -> void:
	await _test_auth_frame_read_on_a_late_poll(testing)
	await _test_silent_peer_closed_after_timeout(testing)


# The editor polls only between frames, and a frame can take longer than the
# timeout while it loads a scene or imports. A client that authenticated right
# away must not be closed because the poll that reads its frame came late.
static func _test_auth_frame_read_on_a_late_poll(testing: Testing) -> void:
	testing.begin("ws transport authenticates a frame that waited for a late poll")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client)

	client.send_text(JSON.stringify({"auth": _TOKEN}))
	client.poll()
	# The delay is the scenario (§9.11): the server's next poll comes after the
	# timeout, with the auth frame already in its buffer.
	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	await transport.poll_peers()
	var authed_count := transport.get_authed_count()
	var ack: String = await _next_frame(transport, client)
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
static func _test_silent_peer_closed_after_timeout(testing: Testing) -> void:
	testing.begin("ws transport closes a peer that never sends its auth frame")
	var transport := _listening_transport()
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % transport.get_bound_port())
	var opened: bool = await _open(transport, client)

	OS.delay_msec(_AUTH_TIMEOUT_MS * 2)
	var closed: Array[WebSocketPeer] = await transport.poll_peers()
	var closed_count := closed.size()
	for _step: int in _HANDSHAKE_STEPS:
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			break
		await transport.poll_peers()
		OS.delay_msec(_STEP_MSEC)
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


## A transport bound to the first free port of the test band, whose message
## handler treats every frame as an auth frame.
static func _listening_transport() -> WsTransport:
	var transport := WsTransport.new()
	transport.configure("[TestAuthTimeout]", _PORT_BASE, _PORT_RANGE, "127.0.0.1", 1,
			_AUTH_TIMEOUT_MS, false, "no free port in %d-%d")
	var on_message := func(peer: WebSocketPeer, text: String) -> void:
		var message: Variant = JSON.parse_string(text)
		if message is Dictionary:
			transport.validate_auth(peer, message)
	transport.set_handlers(on_message, Callable(), Callable(), Callable())
	transport.set_token(_TOKEN)
	transport.ensure_listening()
	return transport


## Drives the server and [param client] until the client's WebSocket is open.
## Returns whether it opened within the bounded number of steps.
static func _open(transport: WsTransport, client: WebSocketPeer) -> bool:
	for _step: int in _HANDSHAKE_STEPS:
		transport.accept_pending()
		await transport.poll_peers()
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
			return true
		OS.delay_msec(_STEP_MSEC)
	return false


## Polls both ends until [param client] receives a frame, and returns its text, or
## "" when none arrives within the bounded number of steps.
static func _next_frame(transport: WsTransport, client: WebSocketPeer) -> String:
	for _step: int in _HANDSHAKE_STEPS:
		await transport.poll_peers()
		client.poll()
		if client.get_available_packet_count() > 0:
			return client.get_packet().get_string_from_utf8()
		OS.delay_msec(_STEP_MSEC)
	return ""
