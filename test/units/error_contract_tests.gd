@tool
extends RefCounted
## Error/response contract unit tests: MCPToolkitError API + code vocabulary,
## debug_bridge error-entry shape, response validation (handler-return contract),
## and the response size guard. Exercises the contract/error surface headless.
##
## run() is a coroutine — the response-validation group awaits registry.call_command().

const PlaytestLogReader := preload("res://addons/godot_mcp_toolkit/commands/playtest_log_reader.gd")


static func run(testing) -> void:
	_test_error_api(testing)
	_test_error_codes_vocabulary(testing)
	_test_make_error_entry(testing)
	_test_response_size_guard(testing)
	# Tail position + INSTANCE handlers (see _Handlers) mirror the proven M3
	# (extension_meta) pattern. On Godot 4.2 a bare static-func Callable stored in the
	# registry and dispatched via `await handler.call()` throws "Invalid get index on
	# Nil" (verified 4.2 vs 4.5); bound instance Callables dispatch fine, like testing.noop.
	await _test_response_validation(testing)


# --- MCPToolkitError API (~5 assertions) ------------------------------------

static func _test_error_api(testing) -> void:
	testing.begin("MCPToolkitError API")

	# 1. fail() returns correct shape
	var not_found_error := MCPToolkitError.fail("NOT_FOUND", "Node missing")
	testing.ok(not_found_error["success"] == false, "fail() → success false")
	testing.eq(not_found_error["error"], "Node missing", "fail() → error message")
	testing.eq(not_found_error["code"], "NOT_FOUND", "fail() → code")

	# 2. fail() with DEFAULT_HINTS code → auto-hint attached
	var timeout_error := MCPToolkitError.fail("TIMEOUT", "Editor busy")
	testing.ok(timeout_error.has("hint"), "fail(TIMEOUT) → auto-hint attached")
	testing.eq(timeout_error["hint"], MCPToolkitError.DEFAULT_HINTS["TIMEOUT"],
			"fail(TIMEOUT) → hint matches DEFAULT_HINTS")

	# 3. fail() with explicit hint → overrides auto-hint
	var explicit_hint_error := MCPToolkitError.fail("TIMEOUT", "Custom", "My hint")
	testing.eq(explicit_hint_error["hint"], "My hint", "fail() explicit hint → overrides auto-hint")

	# 4. fail() with non-DEFAULT_HINTS code and no hint → no hint key
	var no_hint_error := MCPToolkitError.fail("NOT_FOUND", "Missing")
	testing.ok(not no_hint_error.has("hint"), "fail(NOT_FOUND, no hint) → no hint key")

	# 5. require() with all params present → returns null
	var ok_params := {"node_path": "/root/Player", "file_path": "res://s.gd"}
	testing.eq(MCPToolkitError.require(ok_params, ["node_path", "file_path"]), null,
			"require() all present → null")

	# 6. require() with missing param → returns error with hint
	var node_path_only_params := {"node_path": ""}
	var missing_node_path_error = MCPToolkitError.require(node_path_only_params, ["node_path"])
	testing.ok(missing_node_path_error is Dictionary, "require() missing → returns Dictionary")
	testing.eq(missing_node_path_error["code"], "INVALID_PARAMS", "require() missing → INVALID_PARAMS")
	testing.eq(missing_node_path_error["hint"], MCPToolkitError.HINT_NODE_PATH,
			"require(node_path) → HINT_NODE_PATH")

	# 7. require() with missing file_path → HINT_FILE_PATH
	var file_path_only_params := {"file_path": ""}
	var missing_file_path_error = MCPToolkitError.require(file_path_only_params, ["file_path"])
	testing.eq(missing_file_path_error["hint"], MCPToolkitError.HINT_FILE_PATH,
			"require(file_path) → HINT_FILE_PATH")

	print("")


# --- Error-code vocabulary (drift guard) ------------------------------------

## Enforces that MCPToolkitError.CODES is the complete emitted-code vocabulary.
## (a) Every DEFAULT_HINTS key must be in CODES — this exact invariant catches
##     the class of bug where a code is emitted (and given a default hint) but
##     never registered, leaving fail()'s assert and audits with no anchor.
## (b) Codes confirmed emitted by the contract audit must each be in CODES, so
##     a future deletion that re-introduces the drift fails here.
static func _test_error_codes_vocabulary(testing) -> void:
	testing.begin("MCPToolkitError vocabulary")

	# (a) Every DEFAULT_HINTS key is a declared code.
	for key in MCPToolkitError.DEFAULT_HINTS.keys():
		var hint_code: String = str(key)
		testing.ok(MCPToolkitError.CODES.has(hint_code),
				"DEFAULT_HINTS key '%s' present in CODES" % hint_code)

	# (b) Every audit-confirmed emitted code is declared. Sourced from the
	# error-emit-site sweep across addons/ (fail() literals + re-emitted
	# {"code": ...} helper results). Keep in sync when adding error codes.
	var emitted: Array[String] = [
		"ALREADY_EXISTS", "ALREADY_PLAYING", "BUSY", "CLASS_MISMATCH",
		"COMPILATION_FAILED", "CONNECT_FAILED", "CREATE_DIR_FAILED",
		"DELETE_FAILED", "DIR_NOT_EMPTY", "EDITED_SCENE", "EMPTY_CONTENT",
		"EXECUTE_FAILED", "FAILED", "FILE_TOO_LARGE", "FILESYSTEM_NOT_READY",
		"FOLDER_PROTECTED", "GAME_NOT_RUNNING", "HEADLESS_UNSUPPORTED",
		"INTERNAL", "INVALID_CLASS", "INVALID_METHOD", "INVALID_PARAMS",
		"INVALID_PATH", "INVALID_STATE", "INVALID_VALUE", "LOAD_FAILED",
		"LOG_BUSY", "LOG_UNAVAILABLE", "NO_SCENE", "NODE_NOT_FOUND",
		"NOT_A_RESOURCE", "NOT_BREAKED", "NOT_FOUND", "PACK_FAILED",
		"PARENT_NOT_FOUND", "PARSE_ERROR", "PATH_DENIED", "PATH_IN_USE",
		"PROPERTY_NOT_FOUND", "READ_FAILED", "RESPONSE_TOO_LARGE",
		"SAVE_DELETE_FAILED", "SAVE_FAILED", "SAVE_READ_FAILED",
		"SAVE_WRITE_FAILED", "SET_FAILED", "TIMEOUT", "UNKNOWN_CLASS",
		"UNSUPPORTED", "UNSUPPORTED_FILE_TYPE", "WRITE_FAILED",
	]
	for emitted_code in emitted:
		testing.ok(MCPToolkitError.CODES.has(emitted_code),
				"emitted code '%s' present in CODES" % emitted_code)

	# CODES carries no accidental duplicate entry.
	var seen: Dictionary = {}
	var dupes: int = 0
	for entry in MCPToolkitError.CODES:
		var entry_str: String = str(entry)
		if seen.has(entry_str):
			dupes += 1
		seen[entry_str] = true
	testing.eq(dupes, 0, "CODES has no duplicate entries")

	print("")


# --- debug_bridge error-entry shape (single shared constructor) ------------
# make_error_entry is the single shared constructor for the error-buffer dict
# emitted by the live capture path (debug_bridge), the break fallback, and the
# log-scan fallback (playtest_log_reader). Pins the exact key set + order +
# pass-through so the DRY extraction can't drift any one call site's output.
# In-process call (no JSON/WS boundary), so line/timestamp_ms stay true int.

static func _test_make_error_entry(testing) -> void:
	testing.begin("debug_bridge error-entry shape")
	var entry := PlaytestLogReader.make_error_entry(123, "msg", "res://a.gd", "f", 7, "error")
	# exact key set, count, and order-of-keys pinned
	testing.eq(entry.size(), 6, "entry has exactly 6 keys")
	testing.ok(entry.keys() == ["timestamp_ms", "message", "source", "function", "line", "type"],
			"key set + order pinned")
	testing.eq(entry["timestamp_ms"], 123, "timestamp_ms passthrough")
	testing.eq(entry["message"], "msg", "message passthrough")
	testing.eq(entry["source"], "res://a.gd", "source passthrough")
	testing.eq(entry["function"], "f", "function passthrough")
	testing.eq(entry["line"], 7, "line passthrough")
	testing.eq(entry["type"], "error", "type passthrough")
	testing.ok(typeof(entry["line"]) == TYPE_INT, "line is int (no JSON float coercion in-process)")
	testing.ok(typeof(entry["timestamp_ms"]) == TYPE_INT, "timestamp_ms is int")
	# log-scan variant reproduces Site-2 derivation
	var log_scan_entry := PlaytestLogReader.make_error_entry(0, "m2", "", "", 0, "log_scan")
	testing.eq(log_scan_entry["timestamp_ms"], 0, "log_scan timestamp_ms=0 preserved")
	testing.eq(log_scan_entry["type"], "log_scan", "log_scan type preserved")

	print("")


# --- Response validation (~6 assertions) ------------------------------------

# Handler stubs are INSTANCE methods registered as bound Callables: a bare
# static-func Callable does not survive the registry's stored-then-`await
# handler.call()` dispatch on Godot 4.2 (see run()'s note).
class _Handlers extends RefCounted:
	func non_dict(_p: Dictionary) -> String:
		return "not a dictionary"
	func no_success(_p: Dictionary) -> Dictionary:
		return {"data": "missing success"}
	func good(_p: Dictionary) -> Dictionary:
		return {"success": true, "data": "ok"}
	func with_hint(_p: Dictionary) -> Dictionary:
		return {"success": true, "hint": "handler hint"}
	func fail(_p: Dictionary) -> Dictionary:
		return {"success": false, "error": "nope", "code": "TEST"}

static func _test_response_validation(testing) -> void:
	testing.begin("Response validation")
	var handlers := _Handlers.new()
	var registry := MCPToolkitCommandRegistry.new()

	# 1. Handler returns non-Dictionary → INTERNAL error
	registry.add("rv.bad_type", handlers.non_dict,
			MCPToolkitCommandOptions.new())
	var bad_type_result: Dictionary = await registry.call_command("rv.bad_type", {})
	testing.eq(bad_type_result["success"], false, "non-Dict handler → success false")
	testing.eq(bad_type_result["code"], "INTERNAL", "non-Dict handler → INTERNAL code")

	# 2. Handler returns Dict without success → INTERNAL error
	registry.add("rv.no_success", handlers.no_success,
			MCPToolkitCommandOptions.new())
	var no_success_result: Dictionary = await registry.call_command("rv.no_success", {})
	testing.eq(no_success_result["success"], false, "no-success handler → success false")
	testing.eq(no_success_result["code"], "INTERNAL", "no-success handler → INTERNAL code")

	# 3. Good handler → passes through
	registry.add("rv.good", handlers.good, MCPToolkitCommandOptions.new())
	var good_result: Dictionary = await registry.call_command("rv.good", {})
	testing.eq(good_result["success"], true, "good handler → success true")
	testing.eq(good_result["data"], "ok", "good handler → data preserved")

	# 4. with_success_hint() auto-injection on success
	registry.add("rv.hinted", handlers.good,
			MCPToolkitCommandOptions.new().with_success_hint("Next step"))
	var hinted_result: Dictionary = await registry.call_command("rv.hinted", {})
	testing.eq(hinted_result["hint"], "Next step", "with_success_hint → auto-injected")

	# 5. Handler hint overrides registered hint
	registry.add("rv.override", handlers.with_hint,
			MCPToolkitCommandOptions.new().with_success_hint("Registered"))
	var override_result: Dictionary = await registry.call_command("rv.override", {})
	testing.eq(override_result["hint"], "handler hint", "handler hint → overrides registered")

	# 6. No injection on success: false
	registry.add("rv.fail", handlers.fail,
			MCPToolkitCommandOptions.new().with_success_hint("Should not appear"))
	var fail_result: Dictionary = await registry.call_command("rv.fail", {})
	testing.ok(not fail_result.has("hint") or fail_result.get("hint", "") != "Should not appear",
			"success:false → no success_hint injection")

	print("")


# --- Response size guard (~9 assertions) ------------------------------------
# guard_response_size() defends against the native WS send rejecting any frame
# whose payload exceeds the peer's outbound buffer (wholesale, no chunking). It
# is pure dict→dict, so the decision is fully exercisable headless; only the
# live-peer send_text return path needs an editor (covered by dispatch-
# integration flows + smoke at Pass 3).

static func _test_response_size_guard(testing) -> void:
	testing.begin("Response size guard")

	# A roomy cap so an ordinary response is nowhere near the limit.
	var max_bytes := 65536

	# 1. Under-size response → passed through UNCHANGED (same object identity-wise
	#    in content: jsonrpc, id, and result all intact).
	var small := {"jsonrpc": "2.0", "id": 7, "result": {"success": true, "data": "ok"}}
	var guarded_small := MCPToolkitError.guard_response_size(small, max_bytes)
	testing.eq(guarded_small["id"], 7, "under-size → id preserved")
	testing.eq(guarded_small["result"]["success"], true, "under-size → result unchanged")
	testing.eq(guarded_small["result"].get("data", ""), "ok", "under-size → result payload intact")

	# 2. Over-size response → replaced with a compact RESPONSE_TOO_LARGE error,
	#    same id + jsonrpc, and the replacement now fits the cap.
	var filler := "x".repeat(max_bytes + 4096)  # comfortably over the cap
	var big := {"jsonrpc": "2.0", "id": 42, "result": {"success": true, "blob": filler}}
	var guarded_big := MCPToolkitError.guard_response_size(big, max_bytes)
	testing.eq(guarded_big["id"], 42, "over-size → id preserved")
	testing.eq(guarded_big["jsonrpc"], "2.0", "over-size → jsonrpc preserved")
	testing.eq(guarded_big["result"]["success"], false, "over-size → result.success false")
	testing.eq(guarded_big["result"]["code"], "RESPONSE_TOO_LARGE", "over-size → RESPONSE_TOO_LARGE code")
	testing.ok(MCPToolkitError.response_byte_size(guarded_big) <= max_bytes,
			"over-size → replacement fits within max_bytes")

	# 3. Boundary: a response sized just BELOW the (max_bytes − margin) threshold
	#    passes; nudging it just ABOVE the threshold trips the guard. This pins the
	#    margin to the documented value rather than an arbitrary cushion.
	var margin := MCPToolkitError._SIZE_GUARD_MARGIN
	# Envelope overhead (jsonrpc+id+result-wrapping+the "p" key) is a few dozen
	# bytes; subtract a safe pad so the filler alone lands us just under threshold.
	var envelope_pad := 64
	var under_len := (max_bytes - margin) - envelope_pad
	var at_threshold := {"jsonrpc": "2.0", "id": 1, "result": {"p": "y".repeat(under_len)}}
	var guarded_under := MCPToolkitError.guard_response_size(at_threshold, max_bytes)
	testing.ok(guarded_under["result"].has("p"), "boundary just-under → passes through unchanged")
	# A response OVER (max_bytes − margin) but still UNDER max_bytes itself must
	# trip — proving the margin (not the raw buffer cap) is the live threshold.
	var over_len := (max_bytes - margin) + 1024  # ~62464: above threshold, below cap
	var over_threshold := {"jsonrpc": "2.0", "id": 1, "result": {"p": "y".repeat(over_len)}}
	testing.ok(MCPToolkitError.response_byte_size(over_threshold) < max_bytes,
			"boundary over-case is genuinely under the raw cap")
	var guarded_over := MCPToolkitError.guard_response_size(over_threshold, max_bytes)
	testing.eq(guarded_over["result"].get("code", ""), "RESPONSE_TOO_LARGE",
			"boundary over-margin/under-cap → tripped (margin is load-bearing)")

	print("")
