@tool
class_name MCPToolkitError
extends RefCounted
## Shared MCP error contract — canonical error codes and failure envelope.
##
## Every command that fails returns a uniform dictionary built by [method fail]:
## [code]{"success": false, "error": <message>, "code": <code>}[/code], plus an
## optional [code]"hint"[/code] with recovery guidance. [constant CODES] is the
## authoritative vocabulary of [code]code[/code] values; [method require] is the
## shared "required parameters present" check; and [method guard_response_size]
## keeps an oversized response from exceeding the transport buffer. Mirrors
## [MCPToolkitSuccess], which builds the success envelope.[br]
## [br]
## Example:
## [codeblock]
## if node == null:
##     return MCPToolkitError.fail("NODE_NOT_FOUND", "no node at " + path)
## [/codeblock]

## The authoritative set of error [code]code[/code] values a response may carry.
## [method fail] asserts (in debug builds) that the code it is given appears here,
## so an undeclared code is caught as drift during development.
const CODES: Array[String] = [
	"ALREADY_EXISTS",
	"ALREADY_PLAYING",
	"BUSY",
	"CLASS_MISMATCH",
	"COMPILATION_FAILED",
	"CONNECT_FAILED",
	"CREATE_DIR_FAILED",
	"DELETE_FAILED",
	"DIR_NOT_EMPTY",
	"DISCONNECTED",  # Reserved — transport/peer drop; not currently emitted.
	"EDITED_SCENE",
	"EDITOR_VIEWPORT_UNAVAILABLE",
	"EMPTY_CONTENT",
	"EXECUTE_FAILED",
	"EXTERNAL_EDITOR_ACTIVE",
	"FAILED",
	"FILE_TOO_LARGE",
	"FILESYSTEM_NOT_READY",
	"FOLDER_PROTECTED",
	"GAME_NOT_RUNNING",
	"HEADLESS_UNSUPPORTED",
	"INTERNAL",
	"INVALID_CLASS",
	"INVALID_METHOD",
	"INVALID_PARAMS",
	"INVALID_PATH",
	"INVALID_STATE",
	"INVALID_VALUE",
	"LOAD_FAILED",
	"LOG_BUSY",
	"LOG_UNAVAILABLE",
	"NO_SCENE",
	"NODE_NOT_FOUND",
	"NOT_A_RESOURCE",
	"NOT_BREAKED",
	"NOT_FOUND",
	"NOT_UNIQUE",
	"PACK_FAILED",
	"PARENT_NOT_FOUND",
	"PARSE_ERROR",
	"PATH_DENIED",
	"PATH_IN_USE",
	"PROPERTY_NOT_FOUND",
	"READ_FAILED",
	"RESPONSE_TOO_LARGE",
	"RUNTIME_WINDOW_MINIMIZED",
	"SAVE_DELETE_FAILED",
	"SAVE_FAILED",
	"SAVE_READ_FAILED",
	"SAVE_WRITE_FAILED",
	"SET_FAILED",
	"TIMEOUT",
	"UNKNOWN_CLASS",
	"UNSUPPORTED",
	"UNSUPPORTED_FILE_TYPE",
	"WRITE_FAILED",
]

## Recovery hint suggesting how to find a valid node path, for a call site that
## received an unresolvable one. Pass it as the [param hint] of [method fail].
const HINT_NODE_PATH := "Use scene.get_tree to list valid node paths. Root node is always path '.'."

## Recovery hint suggesting how to find a valid file path, for a call site that
## received an unresolvable one. Pass it as the [param hint] of [method fail].
const HINT_FILE_PATH := "Use asset.list to search for files. Paths must start with res://"

## Recovery hint suggesting how to find a valid class name, for a call site that
## received an unknown one. Pass it as the [param hint] of [method fail].
const HINT_CLASS_NAME := "Use classdb.search to find valid class names."

## Per-code default recovery hints, keyed by error code. When [method fail] is
## given an empty hint but the code has an entry here, that hint is auto-attached —
## so codes whose recovery advice never depends on call-site context carry it
## automatically. An explicit [param hint] passed to [method fail] wins over this.
##
## [code]LOG_BUSY[/code] / [code]LOG_UNAVAILABLE[/code] are deliberately absent: their
## recovery advice is version-gated ([code]source="buffer"[/code] is a real fallback only
## on Godot 4.5+), so every emit site passes [method log_busy_hint] /
## [method log_unavailable_hint] explicitly rather than relying on a default here.
const DEFAULT_HINTS := {
	"TIMEOUT": "The editor may be busy. Try editor.wait_for_idle before retrying.",
	"UNSUPPORTED": "Check COMPATIBILITY.md in the godot-mcp-toolkit repository for version requirements.",
	"PATH_DENIED": "Paths must use res:// format. Example: res://scenes/main.tscn",
	"PARENT_NOT_FOUND": "Parent directory does not exist. Use folder.create to create it first.",
	"COMPILATION_FAILED": "The game failed to start due to script errors. Fix the errors shown above, then call game_start again. If no errors are shown, call editor_refresh to retrigger them, then editor_get_console for the full log.",
	"GAME_NOT_RUNNING": "No running game detected. Use game.start first. If the MCP Runtime autoload is missing, re-enable the plugin in Project Settings.",
	"RESPONSE_TOO_LARGE": "The response exceeded the WebSocket transport buffer and could not be delivered. Narrow the query (filter, fewer items, a smaller range) or paginate. If large responses are expected, raise mcp_toolkit/limits/ws_buffer_kb in Project Settings and reconnect.",
}


## Validates that every key listed in [param required] is present in
## [param parameters] as a non-empty string. Returns [code]null[/code] when all
## required keys are satisfied, or an [code]INVALID_PARAMS[/code] error dict (built
## by [method fail], with a path/class recovery hint for known keys) for the first
## missing one. Call it at the top of a handler and return its result if non-null.
static func require(parameters: Dictionary, required: Array) -> Variant:
	for key in required:
		var val = parameters.get(key, "")
		if typeof(val) == TYPE_STRING and val.is_empty():
			var hint := ""
			match key:
				"file_path":
					hint = HINT_FILE_PATH
				"node_path":
					hint = HINT_NODE_PATH
				"path":
					hint = "Provide a res:// folder path. Example: res://scenes/"
				"class_name":
					hint = HINT_CLASS_NAME
			return fail("INVALID_PARAMS", "%s is required" % key, hint)
	return null


## Builds a failure response. [param code] is the machine-readable error code
## (must be one of [constant CODES]); [param message] is the human-readable
## explanation. Returns
## [code]{"success": false, "error": message, "code": code}[/code]. When
## [param hint] is non-empty it is attached as [code]"hint"[/code]; otherwise, if
## [param code] has a [constant DEFAULT_HINTS] entry, that default hint is attached.
## This is the canonical way every handler reports an error.[br]
## [br]
## Example:
## [codeblock]
## return MCPToolkitError.fail("INVALID_PATH", "path must start with res://")
## [/codeblock]
static func fail(code: String, message: String, hint: String = "") -> Dictionary:
	# Debug-only vocabulary guard: an emitted code absent from CODES is drift.
	# Stripped from release builds, so it never affects the wire payload.
	assert(code in CODES, "error code '%s' is not declared in MCPToolkitError.CODES" % code)
	var result := {"success": false, "error": message, "code": code}
	if hint != "":
		result["hint"] = hint
	elif DEFAULT_HINTS.has(code):
		result["hint"] = DEFAULT_HINTS[code]
	return result


## Recovery hint for a [code]LOG_BUSY[/code] failure — the log file exists but a read
## open failed.
##
## Pass the caller's [code]LogBuffer.uses_logger_api()[/code] as [param can_use_buffer]
## ([code]true[/code] on Godot 4.5+): only there is [code]source="buffer"[/code] a real
## file-independent fallback, so it is steered to only then; on 4.2–4.4 the buffer tails
## the same log and would fail identically, so the hint stays stop-game / retry.
## On Windows the dominant cause is a running game: the editor enables safe-save, so its
## READ open requests [code]_SH_DENYWR[/code] (deny-write), which the OS refuses while the
## play process holds the log open for writing — so the file source clears on game exit,
## while [code]source="buffer"[/code] (4.5+) and the in-game runtime reader are unaffected.
## With no game running, the rarer cause is an external holder (antivirus, file-sync,
## backup) briefly locking the file. Unreachable on POSIX (no mandatory share locking).
## Returns the string to pass as [method fail]'s [param hint].
static func log_busy_hint(can_use_buffer: bool) -> String:
	if can_use_buffer:
		return "Use source=\"buffer\" (in-memory, no file I/O — reads even while a game runs). For the file source: on Windows a running game holds the log open, so game_stop then retry; with no game running, a backup/AV/sync tool may briefly hold it — retry shortly."
	return "On Windows a running game holds the log file open — game_stop then read (source=\"buffer\" tails the same file here, so it won't bypass the lock). With no game running, retry shortly (a backup/AV/sync tool may briefly hold it)."


## Recovery hint for a [code]LOG_UNAVAILABLE[/code] failure — the log file could not be
## found or read.
##
## Pass the caller's [code]LogBuffer.uses_logger_api()[/code] as [param can_use_buffer]
## ([code]true[/code] on Godot 4.5+): only there does [code]source="buffer"[/code] work
## independently of file logging, so it is offered only then; on 4.2–4.4 the buffer reads
## the same file and depends on the same setting. Returns the string to pass as
## [method fail]'s [param hint].
static func log_unavailable_hint(can_use_buffer: bool) -> String:
	var hint := "log file could not be read — enable file logging in ProjectSettings → Debug → File Logging → Enable File Logging (debug/file_logging/enable_file_logging), then restart the editor"
	if can_use_buffer:
		return hint + ". Or use source=\"buffer\" (in-memory, real-time — no file needed)."
	return hint + "."


## Tailored RESPONSE_TOO_LARGE hint for an oversized screenshot payload. A capture
## that overflows the buffer has a mode-specific escape hatch the generic hint lacks:
## re-request with [code]image_response_mode:"disk"[/code] to persist the PNG and
## receive only its path, or ask for a smaller size — so the guard swaps this in when
## the over-budget result carries an [code]image_base64[/code].
const _IMAGE_RESPONSE_TOO_LARGE_HINT := "The captured image exceeded the WebSocket transport buffer. Retry with image_response_mode:\"disk\" to save the PNG to disk and receive only its file path, or request a smaller size. Raising mcp_toolkit/limits/ws_buffer_kb in Project Settings also works but requires a reconnect."


## Headroom reserved below max_bytes when guarding a response, in bytes.
##
## The native WS send rejects a frame WHOLESALE — never chunks — when
## `already-queued bytes + this payload > outbound_buffer_size`
## (godotengine/godot wsl_peer.cpp, ERR_OUT_OF_MEMORY; stable 4.2–4.5). The
## checked size is the raw UTF-8 payload, but the comparison also includes
## whatever a prior send has queued-but-not-yet-flushed to a slow peer, plus
## wslay's per-message framing bookkeeping. This margin absorbs that unseen
## in-flight slack so a response we judge "safe" still clears the buffer.
const _SIZE_GUARD_MARGIN := 4096


## Returns the UTF-8 byte length of [param dict] once stringified to JSON — the
## unit the WebSocket send path measures (not character count). Pure; safe to call
## in both the editor and the runtime.
static func response_byte_size(dict: Dictionary) -> int:
	return JSON.stringify(dict).to_utf8_buffer().size()


## Size-guards a fully-built JSON-RPC response against the peer's send buffer.
##
## Returns [param response] unchanged when it fits, or — when its UTF-8 byte
## length would exceed [param max_bytes] minus the framing margin — a size-safe
## replacement that preserves [code]jsonrpc[/code] + [code]id[/code] and swaps
## [code]result[/code] for a compact [code]RESPONSE_TOO_LARGE[/code] failure
## (carrying the recovery hint). The replacement is tiny by construction, so the
## caller can send it without re-checking.[br]
## [br]
## [param max_bytes] is the peer's outbound_buffer_size (captured at accept), so
## the guard works identically for the editor server
## ([code]mcp_toolkit/limits/ws_buffer_kb[/code]) and the runtime server
## (fixed 1 MB) with no ProjectSetting re-read here.
static func guard_response_size(response: Dictionary, max_bytes: int) -> Dictionary:
	if max_bytes <= 0:
		return response  # No buffer cap configured — nothing to guard against.
	if response_byte_size(response) <= max_bytes - _SIZE_GUARD_MARGIN:
		return response
	var safe := {}
	if response.has("jsonrpc"):
		safe["jsonrpc"] = response["jsonrpc"]
	safe["id"] = response.get("id", null)
	# An oversized screenshot payload gets the mode-specific escape hatch (persist to
	# disk / smaller size); any other over-budget result keeps the generic narrow/
	# paginate advice.
	var hint := DEFAULT_HINTS["RESPONSE_TOO_LARGE"]
	var result_payload = response.get("result")
	if typeof(result_payload) == TYPE_DICTIONARY and (result_payload as Dictionary).has("image_base64"):
		hint = _IMAGE_RESPONSE_TOO_LARGE_HINT
	safe["result"] = fail("RESPONSE_TOO_LARGE",
		"response too large for the transport buffer (limit ~%d KB)" % int(max_bytes / 1024),
		hint)
	return safe
