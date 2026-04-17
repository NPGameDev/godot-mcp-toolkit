@tool
class_name MCPError
extends RefCounted
## Shared MCP error contract (I1) — canonical error codes and failure envelope.

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
	"SAVE_FAILED",
	"TIMEOUT",
	"WRITE_FAILED",
]


static func make(code: String, message: String) -> Dictionary:
	return {"success": false, "error": message, "code": code}
