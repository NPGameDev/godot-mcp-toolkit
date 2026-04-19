@tool
extends RefCounted
## Append-only MCP audit log at user://mcp_audit.log.
##
## Each tool dispatch writes one line:
##   <ISO8601Z>\t<method>\t<params_sha256_hex[:12]>
##
## Opened and flushed per write for crash safety. Invoked by
## CommandRegistry.call_command before handler dispatch.

const _LOG_PATH := "user://mcp_audit.log"


static func log_call(method: String, parameters: Dictionary) -> void:
	var timestamp := Time.get_datetime_string_from_system(true) + "Z"
	var params_hash := JSON.stringify(parameters).sha256_text().substr(0, 12)
	var line := "%s\t%s\t%s\n" % [timestamp, method, params_hash]
	var file: FileAccess = null
	if FileAccess.file_exists(_LOG_PATH):
		file = FileAccess.open(_LOG_PATH, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(_LOG_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("MCP audit: could not open %s (err %d)" % [
			_LOG_PATH, FileAccess.get_open_error()])
		return
	file.store_string(line)
	file.flush()
	file.close()
