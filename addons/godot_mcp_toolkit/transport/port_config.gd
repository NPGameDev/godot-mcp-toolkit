@tool
extends RefCounted
## Export-safe resolution of one listen channel's port configuration from the
## environment: a pinned exact port, a relocated scan band, or the built-in
## default band. Shared by the editor server (transport/mcp_server.gd) and the
## Mode-B runtime autoload (runtime/mcp_runtime_server.gd).
##
## Core APIs only (OS.get_environment) — it names zero Editor* symbols and
## preloads nothing editor-tainted, because the runtime autoload preloads this
## file and GDScript resolves identifiers at parse time, so an editor reference
## would parse-fail the autoload in an export template (godot#91713). No
## class_name: consumers reach it as [code]const PortConfig := preload(...)[/code].
##
## The env lookup is injected as an optional Callable so the pure resolution logic
## is unit-testable headlessly — OS.get_environment cannot be set within a running
## process, so tests pass a Dictionary-backed provider instead of the real env.

## The two mutually exclusive per-channel modes. A pin present ⇒ [constant
## MODE_PINNED] and the band is ignored; no pin ⇒ [constant MODE_SCANNED].
const MODE_PINNED := "pinned"
const MODE_SCANNED := "scanned"

# Valid TCP port bounds (inclusive). A pin or band bound outside this is a
# configuration error surfaced to the user, never a silent clamp.
const _PORT_FLOOR := 1
const _PORT_CEIL := 65535


## Resolve one channel's listen configuration from the environment.
##
## [param pin_var] is the exact-port env var (e.g. "GODOT_MCP_EDITOR_PORT");
## [param min_var] / [param max_var] are the scan-band bound vars
## ("..._PORT_MIN" / "..._PORT_MAX"). [param default_min] / [param default_max]
## are the built-in band used when no band env is set. [param getenv] is an
## optional [code]func(name: String) -> String[/code] provider (defaults to
## OS.get_environment) so units can inject a fixed environment.
##
## Returns a Dictionary:
## [br]- [code]mode[/code]: [constant MODE_PINNED] or [constant MODE_SCANNED].
## [br]- [code]port[/code]: the pinned port (pinned mode), else -1.
## [br]- [code]port_min[/code] / [code]port_max[/code]: the scan band (scanned
##   mode); both equal the pin in pinned mode.
## [br]- [code]source[/code]: "env-pin", "env-band", or "default" — for the
##   startup log.
## [br]- [code]band_ignored[/code]: true when a pin AND a band var are both set
##   (the band is ignored — the caller logs a one-line note).
## [br]- [code]error[/code]: empty on success; a ready-to-log message naming the
##   offending var on a malformed pin, an out-of-range value, or MIN > MAX. A
##   non-empty error is fatal for the channel — the caller must NOT fall back to a
##   silent default.
static func resolve(pin_var: String, min_var: String, max_var: String,
		default_min: int, default_max: int, getenv := Callable()) -> Dictionary:
	# OS.get_environment returns a Variant String; the test seam may return
	# anything, so every read is coerced with str() at this dynamic boundary.
	var read: Callable = getenv
	if not read.is_valid():
		read = func(name: String) -> String:
			return OS.get_environment(name)

	var pin_raw := str(read.call(pin_var)).strip_edges()
	var min_raw := str(read.call(min_var)).strip_edges()
	var max_raw := str(read.call(max_var)).strip_edges()
	# Empty string == unset (a bare "GODOT_MCP_EDITOR_PORT=" is treated as absent).
	var band_set := not min_raw.is_empty() or not max_raw.is_empty()

	if not pin_raw.is_empty():
		if not pin_raw.is_valid_int():
			return _error(pin_var, "must be an integer port (got \"%s\")" % pin_raw)
		var pin := pin_raw.to_int()
		if pin < _PORT_FLOOR or pin > _PORT_CEIL:
			return _error(pin_var, "%d is outside the valid port range %d-%d" % [
				pin, _PORT_FLOOR, _PORT_CEIL])
		# Pinned mode wins exclusively — the band is ignored, not blended.
		return {
			"mode": MODE_PINNED,
			"port": pin,
			"port_min": pin,
			"port_max": pin,
			"source": "env-pin",
			"band_ignored": band_set,
			"error": "",
		}

	if not band_set:
		return {
			"mode": MODE_SCANNED,
			"port": -1,
			"port_min": default_min,
			"port_max": default_max,
			"source": "default",
			"band_ignored": false,
			"error": "",
		}

	# Custom band — each bound independently overrides its default; a missing one
	# keeps the default. Both must be integers in range, and MIN <= MAX.
	var low := default_min
	var high := default_max
	if not min_raw.is_empty():
		if not min_raw.is_valid_int():
			return _error(min_var, "must be an integer port (got \"%s\")" % min_raw)
		low = min_raw.to_int()
	if not max_raw.is_empty():
		if not max_raw.is_valid_int():
			return _error(max_var, "must be an integer port (got \"%s\")" % max_raw)
		high = max_raw.to_int()
	if low < _PORT_FLOOR or low > _PORT_CEIL:
		return _error(min_var, "%d is outside the valid port range %d-%d" % [
			low, _PORT_FLOOR, _PORT_CEIL])
	if high < _PORT_FLOOR or high > _PORT_CEIL:
		return _error(max_var, "%d is outside the valid port range %d-%d" % [
			high, _PORT_FLOOR, _PORT_CEIL])
	if low > high:
		return _error(min_var, "%d is greater than %s (%d) — the scan band is empty" % [
			low, max_var, high])
	return {
		"mode": MODE_SCANNED,
		"port": -1,
		"port_min": low,
		"port_max": high,
		"source": "env-band",
		"band_ignored": false,
		"error": "",
	}


# Build a failed-resolution result naming the offending env var so the dock and
# console tell the user exactly what to fix. Mode/port fields are inert (-1) — a
# caller keys off `error` first and treats a non-empty value as fatal.
static func _error(var_name: String, detail: String) -> Dictionary:
	return {
		"mode": MODE_SCANNED,
		"port": -1,
		"port_min": -1,
		"port_max": -1,
		"source": "error",
		"band_ignored": false,
		"error": "%s %s" % [var_name, detail],
	}
