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
	"LOG_BUSY",
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
	"GAME_NOT_RUNNING": "No running game detected. Use game.start first. If the MCP Runtime autoload is missing, re-enable the plugin in Project Settings.",
}


## Validate that all keys in `required` are present and non-empty strings
## in `parameters`. Returns null on success or an INVALID_PARAMS error dict.
static func check_required(parameters: Dictionary, required: Array) -> Variant:
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
			return make("INVALID_PARAMS", "%s is required" % key, hint)
	return null


static func make(code: String, message: String, hint: String = "") -> Dictionary:
	var result := {"success": false, "error": message, "code": code}
	if hint != "":
		result["hint"] = hint
	elif DEFAULT_HINTS.has(code):
		result["hint"] = DEFAULT_HINTS[code]
	return result
