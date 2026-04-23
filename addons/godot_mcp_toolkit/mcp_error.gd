@tool
extends RefCounted
## Shared MCP error contract — canonical error codes and failure envelope.

const CODES: Array[String] = [
	"ALREADY_EXISTS",
	"ALREADY_PLAYING",
	"CONNECT_FAILED",
	"CREATE_DIR_FAILED",
	"DELETE_FAILED",
	"DIR_NOT_EMPTY",
	"DISCONNECTED",
	"EDITED_SCENE",
	"EXECUTE_FAILED",
	"FEATURE_DISABLED",
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
	"LOAD_FAILED",
	"LOG_UNAVAILABLE",
	"NO_SCENE",
	"NOT_A_RESOURCE",
	"NOT_FOUND",
	"PACK_FAILED",
	"PARENT_NOT_FOUND",
	"PARSE_ERROR",
	"PATH_DENIED",
	"PATH_IN_USE",
	"READ_FAILED",
	"SAVE_DELETE_FAILED",
	"SAVE_FAILED",
	"SAVE_READ_FAILED",
	"SAVE_WRITE_FAILED",
	"TIMEOUT",
	"USER_PATH_NOT_WHITELISTED",
	"USER_SCOPE_DISABLED",
	"WRITE_FAILED",
]

## Hint constants for common dead-end recovery at call sites.
const HINT_NODE_PATH := "Use scene.get_tree to list valid node paths."
const HINT_FILE_PATH := "Use asset.list to search for files. Paths must start with res://"
const HINT_CLASS_NAME := "Use classdb.search to find valid class names."

## Default hints auto-attached to error codes that always benefit from
## the same recovery guidance, regardless of call site context.
const DEFAULT_HINTS := {
	"TIMEOUT": "The editor may be busy. Try editor.wait_for_idle before retrying.",
	"UNSUPPORTED": "Check COMPATIBILITY.md for version requirements.",
	"PATH_DENIED": "Paths must use res:// format. Example: res://scenes/main.tscn",
}


static func make(code: String, message: String, hint: String = "") -> Dictionary:
	var result := {"success": false, "error": message, "code": code}
	if hint != "":
		result["hint"] = hint
	elif DEFAULT_HINTS.has(code):
		result["hint"] = DEFAULT_HINTS[code]
	return result
