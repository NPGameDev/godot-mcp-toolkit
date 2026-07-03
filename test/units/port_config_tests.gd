@tool
extends RefCounted
## Deterministic listen-port config unit tests: the pure PortConfig resolver
## (pin / relocated band / default / error cases, via an injected env provider),
## the transport's bind-exact-or-fail pinned mode + scanned-band exhaustion
## (real blocker TCPServer: bounded grace, conflict seam, fresh-bind seam,
## recovery), the editor server's unified not-listening warning selection
## (pinned / range / invalid-config wording + source labels), and the resolver's
## export-cleanliness (no Editor* symbol — the runtime autoload preloads it,
## godot#91713).

const PortConfig := preload("res://addons/godot_mcp_toolkit/transport/port_config.gd")
const WsTransport := preload("res://addons/godot_mcp_toolkit/transport/ws_transport.gd")
const MCPServer := preload("res://addons/godot_mcp_toolkit/transport/mcp_server.gd")

const _RESOLVER_PATH := "res://addons/godot_mcp_toolkit/transport/port_config.gd"


static func run(testing) -> void:
	_test_resolve_pin(testing)
	_test_resolve_band(testing)
	_test_resolve_default(testing)
	_test_resolve_errors(testing)
	_test_pinned_bind_exact_or_fail(testing)
	_test_scanned_band_exhausted(testing)
	_test_port_warning_selection(testing)
	_test_resolver_export_clean(testing)


# Grab a free localhost port and hold it with a blocker TCPServer (fresh probe
# per candidate — a TCPServer that failed listen() latches ERR_ALREADY_IN_USE).
# Returns { "server": TCPServer, "port": int }, or an empty dict if none free.
static func _hold_free_port(from_port: int, to_port: int) -> Dictionary:
	for candidate in range(from_port, to_port):
		var probe := TCPServer.new()
		if probe.listen(candidate, "127.0.0.1") == OK:
			return {"server": probe, "port": candidate}
		probe.stop()
	return {}


# An env provider backed by a fixed Dictionary — the seam that lets the pure
# resolver be tested headlessly (OS.get_environment can't be set in-process).
static func _env(values: Dictionary) -> Callable:
	return func(name: String) -> String:
		return str(values.get(name, ""))


# --- Pure resolver: pinned mode ---------------------------------------------
# A pin present ⇒ Pinned mode, exact port, source "env-pin". A band set alongside
# a pin is ignored (band_ignored true) — the two modes never blend.
static func _test_resolve_pin(testing) -> void:
	testing.begin("PortConfig — pin resolves exact")

	var pinned: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "6557"}))
	testing.eq(str(pinned["mode"]), PortConfig.MODE_PINNED, "pin → pinned mode")
	testing.eq(int(pinned["port"]), 6557, "pin → exact port")
	testing.eq(str(pinned["source"]), "env-pin", "pin → source env-pin")
	testing.ok(str(pinned["error"]).is_empty(), "pin → no error")
	testing.ok(not bool(pinned["band_ignored"]), "pin alone → band not flagged ignored")

	var pin_and_band: Dictionary = PortConfig.resolve(
		"PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "6557", "MIN": "7000", "MAX": "7010"}))
	testing.eq(str(pin_and_band["mode"]), PortConfig.MODE_PINNED, "pin + band → pinned wins")
	testing.ok(bool(pin_and_band["band_ignored"]), "pin + band → band_ignored true (one-line note)")
	print("")


# --- Pure resolver: relocated scan band -------------------------------------
# _MIN/_MAX relocate the scan band; each bound overrides its default
# independently (a missing one keeps the default), source "env-band".
static func _test_resolve_band(testing) -> void:
	testing.begin("PortConfig — _MIN/_MAX relocates the scan")

	var band: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"MIN": "7000", "MAX": "7009"}))
	testing.eq(str(band["mode"]), PortConfig.MODE_SCANNED, "band → scanned mode")
	testing.eq(int(band["port"]), -1, "band → no exact port")
	testing.eq(int(band["port_min"]), 7000, "band → relocated min")
	testing.eq(int(band["port_max"]), 7009, "band → relocated max")
	testing.eq(str(band["source"]), "env-band", "band → source env-band")

	var only_max: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"MAX": "6600"}))
	testing.eq(int(only_max["port_min"]), 6550, "partial band → min keeps its default")
	testing.eq(int(only_max["port_max"]), 6600, "partial band → max overridden")
	testing.eq(str(only_max["source"]), "env-band", "partial band → still env-band")
	print("")


# --- Pure resolver: unchanged default band ----------------------------------
# No env at all ⇒ the built-in default band, source "default" — behaviour
# identical to before this config surface existed.
static func _test_resolve_default(testing) -> void:
	testing.begin("PortConfig — no env keeps the default band")
	var default_band: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({}))
	testing.eq(str(default_band["mode"]), PortConfig.MODE_SCANNED, "no env → scanned mode")
	testing.eq(int(default_band["port_min"]), 6550, "no env → default min")
	testing.eq(int(default_band["port_max"]), 6560, "no env → default max")
	testing.eq(str(default_band["source"]), "default", "no env → source default")
	testing.ok(str(default_band["error"]).is_empty(), "no env → no error")
	print("")


# --- Pure resolver: error cases ---------------------------------------------
# Malformed pin, out-of-range pin, and MIN > MAX each produce a non-empty error
# naming the offending var — never a silent fallback to the default.
static func _test_resolve_errors(testing) -> void:
	testing.begin("PortConfig — clear errors, never a silent default")

	var bad_pin: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "abc"}))
	testing.ok(not str(bad_pin["error"]).is_empty(), "non-integer pin → error")
	testing.ok(str(bad_pin["error"]).contains("PIN"), "non-integer pin error names the pin var")

	var oor_pin: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "70000"}))
	testing.ok(not str(oor_pin["error"]).is_empty(), "out-of-range pin → error")

	var zero_pin: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "0"}))
	testing.ok(not str(zero_pin["error"]).is_empty(), "port 0 → error (out of 1-65535)")

	var inverted: Dictionary = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"MIN": "7010", "MAX": "7000"}))
	testing.ok(not str(inverted["error"]).is_empty(), "MIN > MAX → error")
	testing.ok(str(inverted["error"]).contains("MIN"), "MIN > MAX error names MIN")
	testing.ok(str(inverted["error"]).contains("MAX"), "MIN > MAX error names MAX")
	print("")


# --- Transport: pinned bind-exact-or-fail + bounded grace + recovery ---------
# A pinned-but-occupied port never scans elsewhere: it surfaces the conflict once
# (immediately), retries the SAME port through the bounded grace (idempotent — no
# re-fire), and recovers to the SAME port once it frees — at which point the
# fresh-bind seam fires exactly once (what drives the late registry re-publish).
# Uses a real blocker TCPServer so the whole listen path is exercised, no editor.
static func _test_pinned_bind_exact_or_fail(testing) -> void:
	testing.begin("Transport — pinned bind-exact-or-fail + grace + recovery")

	var held := _hold_free_port(18760, 18800)
	if held.is_empty():
		testing.ok(false, "environment: no free port in 18760-18799 to run the pin-conflict test")
		return
	var blocker: TCPServer = held["server"]
	var blocked_port: int = held["port"]

	var events: Array = []
	var bound_events: Array = []
	var transport := WsTransport.new()
	# relisten_frame_interval = 1 so each attempt costs two ensure_listening() calls
	# (one burns the throttle countdown, one attempts) — keeps the loop tight.
	transport.configure("[TestPin]", blocked_port, 1, "127.0.0.1", 1, 2000, false,
		"no free port in %d-%d", true, "resolution hint")
	transport.set_handlers(Callable(), Callable(), Callable(), Callable(),
		func(port: int): bound_events.append(port),
		func(port: int, active: bool): events.append({"port": port, "active": active}))

	# First attempt: the pinned port is occupied → conflict surfaces immediately.
	transport.ensure_listening()
	testing.ok(transport.is_listen_conflict(), "occupied pin → conflict active after first attempt")
	testing.eq(transport.get_bound_port(), -1, "occupied pin → not bound")
	testing.eq(transport.get_pinned_port(), blocked_port, "pinned port reported")
	testing.eq(events.size(), 1, "conflict seam fired once (detected)")
	testing.ok(bool(events[0]["active"]), "conflict event active = true")
	testing.eq(int(events[0]["port"]), blocked_port, "conflict names the pinned port")

	# Exhaust the bounded grace — still occupied → never scans to another port, and
	# the seam does NOT re-fire (idempotent while the state holds).
	for _i in range(24):
		transport.ensure_listening()
	testing.ok(transport.is_listen_conflict(), "still occupied → conflict persists")
	testing.eq(transport.get_bound_port(), -1, "still occupied → never bound another port")
	testing.eq(events.size(), 1, "conflict seam not re-fired during the grace (idempotent)")
	testing.ok(bound_events.is_empty(), "fresh-bind seam silent while occupied")

	# Free the port → the transport recovers and binds the SAME pinned port.
	blocker.stop()
	blocker = null
	for _j in range(8):
		transport.ensure_listening()
	testing.ok(not transport.is_listen_conflict(), "port freed → conflict cleared")
	testing.eq(transport.get_bound_port(), blocked_port, "recovered → bound the SAME pinned port")
	testing.eq(events.size(), 2, "conflict seam fired again on resolve")
	testing.ok(not bool(events[1]["active"]), "resolve event active = false")
	# The late-bind announce that keeps the registry ground-truth in pin mode.
	testing.eq(bound_events, [blocked_port], "fresh-bind seam fired exactly once, with the pin, on late recovery")

	transport.shutdown_listener()
	print("")


# --- Transport: scanned-band exhaustion feeds the same conflict state --------
# A fully-occupied scan band (default ports too — no env needed) raises the SAME
# listen-conflict the pinned path uses, so the dock warning is not console-only;
# recovery rebinds inside the band, clears the conflict, and announces the bind.
static func _test_scanned_band_exhausted(testing) -> void:
	testing.begin("Transport — scanned band exhausted raises + clears the conflict")

	var held := _hold_free_port(18800, 18840)
	if held.is_empty():
		testing.ok(false, "environment: no free port in 18800-18839 to run the band-exhausted test")
		return
	var blocker: TCPServer = held["server"]
	var blocked_port: int = held["port"]

	var events: Array = []
	var bound_events: Array = []
	var transport := WsTransport.new()
	# Scanned mode with a one-port band = the whole band occupied by the blocker.
	transport.configure("[TestScan]", blocked_port, 1, "127.0.0.1", 1, 2000, false,
		"no free port in %d-%d", false, "")
	transport.set_handlers(Callable(), Callable(), Callable(), Callable(),
		func(port: int): bound_events.append(port),
		func(port: int, active: bool): events.append({"port": port, "active": active}))

	# Exhausted scan → conflict raised (this is what the dock warning reads).
	transport.ensure_listening()
	testing.ok(transport.is_listen_conflict(), "band exhausted → conflict active")
	testing.eq(transport.get_bound_port(), -1, "band exhausted → not bound")
	testing.eq(transport.get_pinned_port(), -1, "scanned mode → no pinned port")
	testing.eq(events.size(), 1, "conflict seam fired once")
	testing.ok(bool(events[0]["active"]), "conflict event active = true")

	# Still exhausted across retries → no seam re-fire, still unbound.
	for _i in range(6):
		transport.ensure_listening()
	testing.eq(events.size(), 1, "conflict seam idempotent while the band stays occupied")
	testing.ok(bound_events.is_empty(), "fresh-bind seam silent while exhausted")

	# Free the band → rebinds INSIDE the band, conflict clears, bind announced.
	blocker.stop()
	blocker = null
	for _j in range(8):
		transport.ensure_listening()
	testing.ok(not transport.is_listen_conflict(), "band freed → conflict cleared")
	testing.eq(transport.get_bound_port(), blocked_port, "recovered → bound inside the band")
	testing.eq(events.size(), 2, "conflict seam fired on resolve")
	testing.ok(not bool(events[1]["active"]), "resolve event active = false")
	testing.eq(bound_events, [blocked_port], "fresh-bind seam fired once on the recovery bind")

	transport.shutdown_listener()
	print("")


# --- Editor server: unified not-listening warning selection ------------------
# get_port_warning() picks the user-facing wording from the resolved config +
# live transport state: invalid config, pinned-port conflict, or band conflict —
# and stays inactive when nothing is wrong. get_port_source() maps the resolved
# source to the status-row token. Drives a real MCPServer instance with a poked
# _port_config and a genuinely-conflicted transport (blocker TCPServer), headless.
static func _test_port_warning_selection(testing) -> void:
	testing.begin("MCPServer — unified not-listening warning selection")

	var server := MCPServer.new()

	# a) Invalid config (bad pin) → "Invalid port config: …", source unresolved.
	server._port_config = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": "abc"}))
	var invalid: Dictionary = server.get_port_warning()
	testing.ok(bool(invalid["active"]), "invalid config → warning active")
	testing.ok(str(invalid["message"]).begins_with("Invalid port config:"),
		"invalid config → 'Invalid port config: {reason}' wording")
	testing.eq(str(invalid["label"]), "invalid port config", "invalid config → concise label")
	testing.eq(server.get_port_source(), "", "invalid config → no source token")

	# Shared blocker + conflicted transport for the two conflict wordings.
	var held := _hold_free_port(18840, 18880)
	if held.is_empty():
		testing.ok(false, "environment: no free port in 18840-18879 to run the warning-selection test")
		server.free()
		return
	var blocker: TCPServer = held["server"]
	var blocked_port: int = held["port"]

	# b) Pinned conflict → "Pinned port: {port} not available".
	var pin_transport := WsTransport.new()
	pin_transport.configure("[TestWarnPin]", blocked_port, 1, "127.0.0.1", 1, 2000, false,
		"no free port in %d-%d", true, "hint")
	pin_transport.set_handlers(Callable(), Callable(), Callable(), Callable())
	pin_transport.ensure_listening()
	server._port_config = PortConfig.resolve(
		"PIN", "MIN", "MAX", 6550, 6560, _env({"PIN": str(blocked_port)}))
	server._transport = pin_transport
	var pinned: Dictionary = server.get_port_warning()
	testing.ok(bool(pinned["active"]), "pinned conflict → warning active")
	testing.ok(str(pinned["message"]).begins_with("Pinned port: %d not available" % blocked_port),
		"pinned conflict → 'Pinned port: {port} not available' wording")
	testing.eq(str(pinned["label"]), "pinned port %d not available" % blocked_port,
		"pinned conflict → concise label names the pin")
	testing.eq(server.get_port_source(), "pinned", "pin → source token 'pinned'")
	pin_transport.shutdown_listener()

	# c) Band conflict (custom band AND default band share the wording) →
	#    "Range of ports: {min}-{max} not available".
	var band_transport := WsTransport.new()
	band_transport.configure("[TestWarnBand]", blocked_port, 1, "127.0.0.1", 1, 2000, false,
		"no free port in %d-%d", false, "")
	band_transport.set_handlers(Callable(), Callable(), Callable(), Callable())
	band_transport.ensure_listening()
	server._port_config = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560,
		_env({"MIN": str(blocked_port), "MAX": str(blocked_port)}))
	server._transport = band_transport
	var banded: Dictionary = server.get_port_warning()
	testing.ok(bool(banded["active"]), "band conflict → warning active")
	testing.ok(str(banded["message"]).begins_with(
		"Range of ports: %d-%d not available" % [blocked_port, blocked_port]),
		"band conflict → 'Range of ports: {min}-{max} not available' wording")
	testing.eq(str(banded["label"]), "ports %d-%d not available" % [blocked_port, blocked_port],
		"band conflict → concise label names the range")
	testing.eq(server.get_port_source(), "band", "band → source token 'band'")

	# d) Conflict cleared → inactive (default config, freed transport).
	blocker.stop()
	blocker = null
	for _i in range(8):
		band_transport.ensure_listening()
	server._port_config = PortConfig.resolve("PIN", "MIN", "MAX", 6550, 6560, _env({}))
	var healthy: Dictionary = server.get_port_warning()
	testing.ok(not bool(healthy["active"]), "bound transport + clean config → warning inactive")
	testing.eq(server.get_port_source(), "default", "no env → source token 'default'")
	band_transport.shutdown_listener()

	server._transport = null
	server.free()
	print("")


# --- Resolver export-cleanliness (godot#91713) ------------------------------
# The runtime autoload preloads PortConfig, so its static graph must name zero
# editor-only symbols or the autoload parse-fails in an export template. A
# source scan of the code (comments stripped) asserts no Editor* identifier.
static func _test_resolver_export_clean(testing) -> void:
	testing.begin("PortConfig export-clean (no Editor symbols)")
	var file := FileAccess.open(_RESOLVER_PATH, FileAccess.READ)
	testing.ok(file != null, "resolver source opens")
	if file == null:
		print("")
		return
	var source := file.get_as_text()
	file.close()

	var offending: Array[String] = []
	for raw_line in source.split("\n"):
		var line: String = raw_line
		# Strip the comment tail (the resolver has no '#' inside a string literal),
		# so a comment that mentions "Editor*" doesn't count as a code taint.
		var hash_index := line.find("#")
		var code: String = line if hash_index < 0 else line.substr(0, hash_index)
		if code.contains("Editor"):
			offending.append(line.strip_edges())
	testing.eq(offending.size(), 0,
		"no Editor* identifier in resolver code (runtime autoload preloads it — godot#91713)")
	print("")
