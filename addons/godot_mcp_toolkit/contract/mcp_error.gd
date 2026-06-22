@tool
class_name MCPToolkitError
extends RefCounted
## Shared MCP error contract — canonical error codes and failure envelope.

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
	"EMPTY_CONTENT",
	"EXECUTE_FAILED",
	"FAILED",
	"FEATURE_DISABLED",  # Reserved — read-only/profile gating; not currently emitted.
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
	"PACK_FAILED",
	"PARENT_NOT_FOUND",
	"PARSE_ERROR",
	"PATH_DENIED",
	"PATH_IN_USE",
	"PROPERTY_NOT_FOUND",
	"READ_FAILED",
	"RESPONSE_TOO_LARGE",
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

## Hint constants for common dead-end recovery at call sites.
const HINT_NODE_PATH := "Use scene.get_tree to list valid node paths. Root node is always path '.'."
const HINT_FILE_PATH := "Use asset.list to search for files. Paths must start with res://"
const HINT_CLASS_NAME := "Use classdb.search to find valid class names."

## Default hints auto-attached to error codes that always benefit from
## the same recovery guidance, regardless of call site context.
const DEFAULT_HINTS := {
	"TIMEOUT": "The editor may be busy. Try editor.wait_for_idle before retrying.",
	"UNSUPPORTED": "Check COMPATIBILITY.md for version requirements.",
	"PATH_DENIED": "Paths must use res:// format. Example: res://scenes/main.tscn",
	"LOG_BUSY": "Log file is temporarily locked by the engine's flush. Retry in 1-2 seconds, or use source=\"buffer\" instead.",
	"LOG_UNAVAILABLE": "Log file could not be read. Enable file logging in ProjectSettings → Debug → File Logging → Enable File Logging (debug/file_logging/enable_file_logging). If the editor just started, the log may not exist yet. Use source=\"buffer\" for real-time output.",
	"PARENT_NOT_FOUND": "Parent directory does not exist. Use folder.create to create it first.",
	"COMPILATION_FAILED": "The game failed to start due to script errors. Fix the errors shown above, then call game_start again. If no errors are shown, call editor_refresh to retrigger them, then editor_get_console for the full log.",
	"GAME_NOT_RUNNING": "No running game detected. Use game.start first. If the MCP Runtime autoload is missing, re-enable the plugin in Project Settings.",
	"RESPONSE_TOO_LARGE": "The response exceeded the WebSocket transport buffer and could not be delivered. Narrow the query (filter, fewer items, a smaller range) or paginate. If large responses are expected, raise mcp_toolkit/limits/ws_buffer_kb in Project Settings and reconnect.",
}


## Validate that all keys in `required` are present and non-empty strings
## in `parameters`. Returns null on success or an INVALID_PARAMS error dict.
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
				"folder_path":
					hint = "Provide a res:// folder path. Example: res://scenes/"
				"class_name":
					hint = HINT_CLASS_NAME
			return fail("INVALID_PARAMS", "%s is required" % key, hint)
	return null


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


## UTF-8 byte length of `dict` once stringified — the unit the WS send path
## measures (not character count). Pure; safe in editor and runtime.
static func response_byte_size(dict: Dictionary) -> int:
	return JSON.stringify(dict).to_utf8_buffer().size()


## Size-guard a fully-built JSON-RPC response against the peer's send buffer.
##
## Returns `response` unchanged when it fits, or — when its UTF-8 byte length
## would exceed `max_bytes` minus the framing margin — a size-safe replacement
## that preserves `jsonrpc` + `id` and swaps `result` for a compact
## RESPONSE_TOO_LARGE failure (carrying the recovery hint). The replacement is
## tiny by construction, so the caller can send it without re-checking.
##
## `max_bytes` is the peer's outbound_buffer_size (captured at accept), so the
## guard works identically for the editor server (mcp_toolkit/limits/ws_buffer_kb)
## and the runtime server (fixed 1 MB) with no ProjectSetting re-read here.
static func guard_response_size(response: Dictionary, max_bytes: int) -> Dictionary:
	if max_bytes <= 0:
		return response  # No buffer cap configured — nothing to guard against.
	if response_byte_size(response) <= max_bytes - _SIZE_GUARD_MARGIN:
		return response
	var safe := {}
	if response.has("jsonrpc"):
		safe["jsonrpc"] = response["jsonrpc"]
	safe["id"] = response.get("id", null)
	safe["result"] = fail("RESPONSE_TOO_LARGE",
		"response too large for the transport buffer (limit ~%d KB)" % int(max_bytes / 1024),
		DEFAULT_HINTS["RESPONSE_TOO_LARGE"])
	return safe
