@tool
extends RefCounted
## Owns a bound TCP listener and its WebSocket peers: scan/listen (incl. the
## ERR_ALREADY_IN_USE discard-recreate), accept, the auth-handshake framing, peer
## lifecycle, and the auth timeout — driven by an externally-scheduled pump()
## primitive (the CALLER decides cadence). The "when" and the side-effects stay in
## the owning server, injected as Callables; this base only gets bytes on/off the
## wire and tracks peer state.
##
## Export-clean by contract: the Mode-B runtime autoload preloads this file, and
## GDScript resolves identifiers at parse time (before any is_editor_hint() guard),
## so naming ANY editor-only class — or preloading a script that does — would
## parse-fail the autoload in an export template (godotengine/godot#91713, unfixed
## 4.2–4.6). The entire identifier set here is TCPServer / WebSocketPeer / JSON /
## Time / ProjectSettings / MCPAuth, and it preloads only export-clean files. Keep
## it that way: a grep for "Editor" must return zero non-comment hits.

const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")

# Pinned mode retries the SAME occupied port this many throttled times (a bounded
# "grace" that rides out an old instance still releasing it on restart) before
# logging the precise error. It keeps watching the port afterwards, so a later
# free still recovers — the bound is only on the loud-log phase, not on recovery.
const _PIN_GRACE_ATTEMPTS := 5

# Injected by the owning server after construction. The base is mechanical; every
# decision/side-effect that differs between the editor (Mode A) and the runtime
# (Mode B) rides one of these seams.
#
# _on_message:      func(peer: WebSocketPeer, text: String) -> void
#   The server's orchestrator: parses the frame and routes auth-vs-dispatch
#   (calling validate_auth() for the auth branch, its own dispatch otherwise).
#   May return a coroutine — poll_peers() awaits it, so the editor's per-tick
#   sequential dispatch is preserved (awaiting a synchronous call is a no-op, so
#   the runtime's non-await behaviour is preserved too).
# _build_auth_ack:  func(message: Dictionary) -> Dictionary
#   The server supplies the auth-ack payload (editor adds godot_version+version;
#   runtime returns {"authed": true}). Pure — no side effects.
# _on_peer_authed:  func(count: int) -> void
#   Fired after a successful auth (editor → unfocused boost on the first peer +
#   client_connected; runtime → noop).
# _on_peer_closed:  func(peer: WebSocketPeer, was_authed: bool) -> void
#   Fired once per closed peer during cleanup (editor → lease cleanup + unfocused
#   restore + client_disconnected; runtime → noop).
# _on_bound:        func(port: int) -> void
#   Fired the moment a fresh port scan binds (NOT on an idempotent rebind), so a
#   server can publish the new port (runtime → RegistryClient.set_runtime; editor
#   → noop). Mirrors where the pre-extraction runtime called set_runtime.
# _on_listen_conflict: func(port: int, active: bool) -> void
#   Fired on a listen-conflict STATE CHANGE — the listener tried and failed to bind
#   anywhere it is allowed to (pinned port occupied, scan band exhausted, or a lost
#   rebind), or that condition cleared (active=false on a successful bind). port is
#   the pinned port / band base. The editor routes it to the dock warning + status
#   label; the runtime leaves it empty (a child game process can't touch the dock)
#   and relies on the transport's push_warning/push_error in the game console.
var _on_message: Callable = Callable()
var _build_auth_ack: Callable = Callable()
var _on_peer_authed: Callable = Callable()
var _on_peer_closed: Callable = Callable()
var _on_bound: Callable = Callable()
var _on_listen_conflict: Callable = Callable()

# Tagging prefix for the listen/accept warnings, supplied by the owning server so
# the editor and the runtime keep their distinct console labels.
var _log_prefix: String = "[MCPServer]"
# The warning logged when the whole port range is exhausted. Server-supplied
# (verbatim) because the editor and the runtime word it differently — a "%d/%d"
# format the base fills with the low/high port. The prefix is prepended.
var _exhausted_warning: String = "no free port in %d-%d; will retry every ~1s"
# Port scan range and the bind address, supplied at construction (the editor and
# the runtime listen on different port ranges).
var _port_base: int = 6550
var _port_range: int = 11
var _bind: String = "127.0.0.1"
# Throttle re-listen retries to avoid log spam while a port is briefly held by
# another process. ~1s at 60fps; the bridge's reconnect backoff sits on the same
# order so we don't pile retries on top of it.
var _relisten_frame_interval: int = 60
# Peers that don't send a valid auth message within this window are closed with WS
# code 1008 (Policy Violation).
var _auth_timeout_ms: int = 2000
# Whether poll_peers() AWAITS each _on_message delivery. The editor (Mode A)
# awaits so dispatch stays strictly sequential within a poll tick (its mutation
# serialisation depends on this); the runtime (Mode B) does NOT await — it
# fire-and-forgets, so a coroutine handler (e.g. runtime.screenshot, which awaits
# frame_post_draw) runs independently and the poll loop completes its pass. This
# matches each server's pre-extraction behaviour exactly.
var _await_messages: bool = true
# Pinned mode: bind the exact _port_base or fail — never scan to another port
# (deterministic multi-instance). A pinned-but-occupied port surfaces immediately
# and retries the SAME port for the bounded _PIN_GRACE_ATTEMPTS grace. Scanned
# mode (the default) is unchanged.
var _pinned: bool = false
# Server-supplied "how to resolve" tail appended to the precise pinned-conflict
# error, so the editor and the runtime word the fix for their own env var.
var _pin_conflict_hint: String = ""

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []
var _peer_authed: Dictionary = {}       # WebSocketPeer -> true (authed peers only)
var _peer_connect_ms: Dictionary = {}   # WebSocketPeer -> int (ticks_msec at accept)
var _relisten_countdown: int = 0
# Tracks the current run of consecutive listen failures so we log the first one
# (with a hint), stay silent during retries, and announce the recovery with the
# attempt count. Reset on every successful listen.
var _consecutive_failures: int = 0
# -1 = never bound.
var _bound_port: int = -1
var _session_token: String = ""
# True while the listener has tried and failed to bind anywhere it is allowed to
# — a pinned port occupied, the scan band exhausted, or a lost rebind. Drives the
# editor dock warning + status label (via _on_listen_conflict). Cleared on any
# successful bind.
var _listen_conflict: bool = false
# Remaining bounded same-port grace attempts before the precise error is logged.
var _pin_grace_remaining: int = 0
# One-shot latch so the precise post-grace error logs once, not on every retry.
var _pin_error_logged: bool = false


## Configure the listener parameters and the console label. Called once by the
## owning server right after construction, before the first pump(). await_messages
## selects the dispatch semantics (see the field doc): editor true, runtime false.
## exhausted_warning is the server's verbatim port-range-exhausted message (a
## "%d/%d" format for the low/high port; prefix prepended). When pinned is true,
## port_range must be 1 and port_base is the exact pin — the listener binds it or
## fails (bind-exact-or-fail), never scanning elsewhere; pin_conflict_hint is the
## server's "how to resolve" tail appended to the precise conflict error.
func configure(log_prefix: String, port_base: int, port_range: int, bind: String,
		relisten_frame_interval: int, auth_timeout_ms: int,
		await_messages: bool, exhausted_warning: String,
		pinned: bool = false, pin_conflict_hint: String = "") -> void:
	_log_prefix = log_prefix
	_port_base = port_base
	_port_range = port_range
	_bind = bind
	_relisten_frame_interval = relisten_frame_interval
	_auth_timeout_ms = auth_timeout_ms
	_await_messages = await_messages
	_exhausted_warning = exhausted_warning
	_pinned = pinned
	_pin_conflict_hint = pin_conflict_hint
	if pinned:
		_pin_grace_remaining = _PIN_GRACE_ATTEMPTS


## Inject the per-server seams (see the field docs above). Called once by the
## owning server right after configure(). A server that has no use for a seam
## (e.g. the runtime needs no auth-ack override or close/authed side-effects)
## passes an empty Callable and the base falls back to its mechanical default.
func set_handlers(on_message: Callable, build_auth_ack: Callable,
		on_peer_authed: Callable, on_peer_closed: Callable,
		on_bound: Callable = Callable(),
		on_listen_conflict: Callable = Callable()) -> void:
	_on_message = on_message
	_build_auth_ack = build_auth_ack
	_on_peer_authed = on_peer_authed
	_on_peer_closed = on_peer_closed
	_on_bound = on_bound
	_on_listen_conflict = on_listen_conflict


func set_token(token: String) -> void:
	_session_token = token


## The current session token, so a server that must re-write it to a new user://
## path (after a config/name change) can read it without holding its own copy.
func get_token() -> String:
	return _session_token


func is_listening() -> bool:
	return _tcp_server != null and _tcp_server.is_listening()


func get_bound_port() -> int:
	return _bound_port


## True while the listener has tried and failed to bind anywhere it is allowed to
## (pinned port occupied, scan band exhausted, or a lost rebind). The editor
## server surfaces this as a dock warning + status-label state.
func is_listen_conflict() -> bool:
	return _listen_conflict


## The exact port this transport must bind in pinned mode, else -1.
func get_pinned_port() -> int:
	return _port_base if _pinned else -1


func is_authed(peer: WebSocketPeer) -> bool:
	return _peer_authed.has(peer)


func get_authed_count() -> int:
	return _peer_authed.size()


## The authenticated peers (for broadcast). Returned as the raw key array the
## Notifier.broadcast helper expects; callers must not mutate the maps through it.
func get_authed_peers() -> Array:
	return _peer_authed.keys()


# -- Pump primitive ------------------------------------------------------------


## Drive ONE listen-maintain + accept + poll-peers + cleanup cycle. The CALLER
## decides cadence (editor: call_deferred @ ~15 Hz, gated by is_dispatching();
## runtime: inline per frame). Returns after one pass; never loops on its own.
## Returns true if an authed peer closed this pass, so the caller can emit a single
## aggregated disconnect per tick (the editor uses this; the runtime ignores it).
##
## Ordering mirrors the pre-extraction servers exactly: if the listener is down,
## try to (re)listen and return WITHOUT accepting/polling this tick; otherwise
## accept pending connections, poll the peers, and clean up the ones that closed.
func pump() -> bool:
	if _tcp_server == null or not _tcp_server.is_listening():
		ensure_listening()
		return false
	accept_pending()
	var closed := await poll_peers()
	return cleanup(closed)


# -- Listen / re-listen --------------------------------------------------------


## First-time port scan OR idempotent re-listen, matching the pre-extraction
## split: with no bound port yet, scan the range; with a known port, retry it
## (throttled). On a failed retry, discard the latched TCPServer and recreate it
## next attempt (a TCPServer that failed listen() latches
## ERR_ALREADY_IN_USE if reused).
func ensure_listening() -> void:
	# Already listening → nothing to ensure. Without this guard a call while live
	# would stop + re-listen the same socket (listen() on an already-open TCPServer
	# fails ERR_ALREADY_IN_USE), briefly dropping the listener and flapping the
	# conflict state. pump() gates on is_listening() so it never hits this; the
	# guard makes the method safe for ANY caller.
	if _tcp_server != null and _tcp_server.is_listening():
		return
	# Throttle the retry FIRST (matches the pre-extraction _try_listen ordering),
	# so an armed countdown gates BOTH a re-scan (no port bound yet) and a rebind.
	# At the initial start() call the countdown is 0, so the first scan is immediate.
	if _relisten_countdown > 0:
		_relisten_countdown -= 1
		return
	if _bound_port < 0:
		if _pinned:
			_pin_listen()
		else:
			_scan_and_listen()
		return
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var error := _tcp_server.listen(_bound_port, _bind)
	if error == OK:
		_note_listen_success(true)
		return
	var hint := ""
	if error == ERR_ALREADY_IN_USE:
		hint = " (ERR_ALREADY_IN_USE — will retry silently every ~1s)"
	_tcp_server.stop()
	_note_listen_failure("%s rebind %s:%d failed (err %d)%s" % [
		_log_prefix, _bind, _bound_port, error, hint])


# Tries _port_base.._port_base+_port_range-1 and binds the first free port. Sets
# _bound_port on success. If none is free, arms the throttled retry.
func _scan_and_listen() -> void:
	for offset in range(_port_range):
		var candidate := _port_base + offset
		var server := TCPServer.new()
		var err := server.listen(candidate, _bind)
		if err == OK:
			_tcp_server = server
			_bound_port = candidate
			_note_listen_success(false)
			print("%s listening on %s:%d" % [_log_prefix, _bind, _bound_port])
			if _on_bound.is_valid():
				_on_bound.call(_bound_port)
			return
		server.stop()
	# Server-supplied verbatim message (editor and runtime word it differently).
	_note_listen_failure("%s %s" % [
		_log_prefix, _exhausted_warning % [_port_base, _port_base + _port_range - 1]])


# Pinned mode: bind the exact _port_base or fail — never scans to another port.
# The first conflict surfaces immediately (dock warning via _on_listen_conflict +
# a push_warning); the SAME port is retried for a bounded grace — with a fresh
# TCPServer per attempt, because an instance that failed listen() latches
# ERR_ALREADY_IN_USE if reused — to ride out a prior instance still releasing it;
# grace exhausted → one precise push_error; a later success clears the conflict
# and rebinds. Loud and deterministic — never a silent fallback to a different
# port, never a silent hang.
func _pin_listen() -> void:
	if _tcp_server == null:
		_tcp_server = TCPServer.new()
	var error := _tcp_server.listen(_port_base, _bind)
	if error == OK:
		_bound_port = _port_base
		_consecutive_failures = 0
		_relisten_countdown = 0
		print("%s listening on %s:%d" % [_log_prefix, _bind, _bound_port])
		if _on_bound.is_valid():
			_on_bound.call(_bound_port)
		if _listen_conflict:
			print("%s pinned port %d is now free - bound after the conflict cleared" % [
				_log_prefix, _port_base])
			_set_listen_conflict(false)
		_pin_grace_remaining = _PIN_GRACE_ATTEMPTS
		_pin_error_logged = false
		return
	# Occupied (or another bind failure) — drop the failed server so the next
	# attempt starts from a fresh instance (a reused one keeps failing with the
	# latched ERR_ALREADY_IN_USE), then arm the throttled retry.
	_tcp_server.stop()
	_tcp_server = null
	if not _listen_conflict:
		push_warning("%s pinned port %d in use - retrying the same port briefly in case a prior instance is still releasing it" % [
			_log_prefix, _port_base])
		_set_listen_conflict(true)
	if _pin_grace_remaining > 0:
		_pin_grace_remaining -= 1
		if _pin_grace_remaining == 0 and not _pin_error_logged:
			_pin_error_logged = true
			push_error("%s could not bind pinned port %d - it is still in use. %s" % [
				_log_prefix, _port_base, _pin_conflict_hint])
	_relisten_countdown = _relisten_frame_interval


# Flip the listen-conflict flag and notify the owner on a state CHANGE only (the
# editor surfaces/clears the dock warning + status label; the runtime passes no
# handler). Kept idempotent so repeated failures while the state holds don't
# re-fire the seam.
func _set_listen_conflict(active: bool) -> void:
	if _listen_conflict == active:
		return
	_listen_conflict = active
	if _on_listen_conflict.is_valid():
		_on_listen_conflict.call(_port_base, active)


# Records a failed listen (scan-band exhausted, or a lost rebind): bumps the
# failure count, warns once on the first failure of the streak, drops the dead
# server (a TCPServer that failed listen() latches ERR_ALREADY_IN_USE — the next
# attempt needs a fresh instance), raises the listen-conflict state for the dock,
# and arms the throttled retry.
func _note_listen_failure(warning: String) -> void:
	_consecutive_failures += 1
	if _consecutive_failures == 1:
		push_warning(warning)
	_tcp_server = null
	_set_listen_conflict(true)
	_relisten_countdown = _relisten_frame_interval


# Records a successful listen: clears the failure streak, the retry latch, and
# the listen-conflict state. When recovering from a prior failure run, logs the
# recovery (the fresh first-boot scan passes false and skips that line).
func _note_listen_success(emit_recovery_log: bool) -> void:
	if emit_recovery_log and _consecutive_failures > 0:
		print("%s listening on %s:%d (recovered after %d failed attempts)" % [
			_log_prefix, _bind, _bound_port, _consecutive_failures])
	_consecutive_failures = 0
	_relisten_countdown = 0
	_set_listen_conflict(false)


# -- Accept / poll / cleanup ---------------------------------------------------


## Accept every pending connection: take the stream, wrap it in a WebSocketPeer
## with its inbound/outbound buffer sized from ws_buffer_kb (read ONCE here —
## this is the single home for that ProjectSetting read), track the peer and its
## connect time. ProjectSettings is a core singleton (present at runtime), so
## reading it keeps the base export-clean.
func accept_pending() -> void:
	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var buffer_kb: int = ProjectSettings.get_setting("mcp_toolkit/limits/ws_buffer_kb", 1024)
		peer.inbound_buffer_size = buffer_kb * 1024
		peer.outbound_buffer_size = buffer_kb * 1024
		var accept_error := peer.accept_stream(stream)
		if accept_error != OK:
			push_warning("%s accept_stream failed (%d)" % [_log_prefix, accept_error])
			continue
		_peers.append(peer)
		_peer_connect_ms[peer] = Time.get_ticks_msec()


## Poll each peer; enforce the auth timeout (close 1008 if a peer hasn't authed in
## time); drain available packets, delivering each frame to _on_message (awaited
## so the editor's per-tick sequential dispatch is preserved). Returns the peers
## that have closed, for cleanup().
func poll_peers() -> Array[WebSocketPeer]:
	var closed: Array[WebSocketPeer] = []
	var now_ms := Time.get_ticks_msec()
	for peer in _peers:
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			closed.append(peer)
			continue
		if state != WebSocketPeer.STATE_OPEN:
			continue
		# Auth timeout — close peers that haven't authed in time.
		if not _peer_authed.has(peer):
			if now_ms - int(_peer_connect_ms.get(peer, 0)) > _auth_timeout_ms:
				peer.close(1008, "auth timeout")
				closed.append(peer)
				continue
		while peer.get_available_packet_count() > 0:
			var text := peer.get_packet().get_string_from_utf8()
			# Editor awaits (sequential dispatch within the tick); runtime fires
			# and forgets (a coroutine handler runs independently). See _await_messages.
			if _await_messages:
				await _on_message.call(peer, text)
			else:
				_on_message.call(peer, text)
	return closed


## Erase the peer maps for the closed peers and fire _on_peer_closed for each (the
## server does its lease/unfocused/signal cleanup there). was_authed is read
## BEFORE the erase so the server can tell whether an authed peer dropped. Returns
## true if ANY closed peer was authed, so the server can emit a single aggregated
## disconnect per batch (the pre-extraction shape) with a reentrancy-safe local.
func cleanup(closed: Array[WebSocketPeer]) -> bool:
	var had_authed_disconnect := false
	for peer in closed:
		var was_authed := _peer_authed.has(peer)
		if was_authed:
			had_authed_disconnect = true
		_peers.erase(peer)
		_peer_authed.erase(peer)
		_peer_connect_ms.erase(peer)
		if _on_peer_closed.is_valid():
			_on_peer_closed.call(peer, was_authed)
	return had_authed_disconnect


# -- Auth handshake ------------------------------------------------------------


## Validate a parsed auth message against the session token. On success: mark the
## peer authed, send the server-supplied auth-ack frame, fire _on_peer_authed with
## the new authed count, and return true. On failure: close 1008 and return false.
## The ack PAYLOAD is server-supplied (editor vs runtime diverge); the framing is
## the base's.
func validate_auth(peer: WebSocketPeer, message: Dictionary) -> bool:
	if not MCPAuth.validate(message, _session_token):
		peer.close(1008, "invalid token")
		return false
	_peer_authed[peer] = true
	var ack: Dictionary = {"authed": true}
	if _build_auth_ack.is_valid():
		ack = _build_auth_ack.call(message)
	peer.send_text(JSON.stringify(ack))
	if _on_peer_authed.is_valid():
		_on_peer_authed.call(_peer_authed.size())
	return true


# -- Teardown ------------------------------------------------------------------


## Close every peer with the given code/reason and clear the peer maps. Used by
## the server's stop() (1000) and regenerate_token() (1008 — peers must re-auth).
## Does NOT touch the TCPServer; the server's stop() owns that.
func close_all(code: int, reason: String) -> void:
	for peer in _peers:
		if peer != null:
			if reason.is_empty():
				peer.close(code)
			else:
				peer.close(code, reason)
	_peers.clear()
	_peer_authed.clear()
	_peer_connect_ms.clear()


## Stop and discard the TCPServer and reset the listen bookkeeping — the final
## teardown step, for after every peer has been closed via close_all().
func shutdown_listener() -> void:
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_relisten_countdown = 0
	_consecutive_failures = 0
	_bound_port = -1
	_set_listen_conflict(false)
	_pin_grace_remaining = _PIN_GRACE_ATTEMPTS if _pinned else 0
	_pin_error_logged = false
