@tool
extends RefCounted
## Repository for the project-root .mcp.json file.
##
## Owns all plugin access to .mcp.json: it reads (path resolution, the
## godot-mcp-toolkit server entry's env vars, read-only detection) AND
## performs the plugin-initiated template write. The file remains
## user-owned for edits; the plugin only ever writes it from the bundled
## template on explicit user action (the dock's / Tools-menu's "Write
## .mcp.json").
##
## UI-free by design: the write reports its outcome through an injected
## on_result Callable so the overwrite-confirmation dialog and the toasts
## stay in the dock (the editor-UI owner); this repository touches only
## the file and never reaches EditorInterface / a dialog / a toast.

# Bundled source the plugin-initiated write copies from.
const _TEMPLATE_PATH := "res://addons/godot_mcp_toolkit/.mcp.json.template"

# Reused JSON parser — avoids allocating a JSON on every poll (the dock re-checks
# .mcp.json validity ~1s). Editor-only + main-thread, so one shared instance is
# safe; each parse() overwrites the prior data.
static var _json := JSON.new()


static func get_mcp_json_path() -> String:
	return ProjectSettings.globalize_path("res://") + ".mcp.json"


static func has_mcp_json() -> bool:
	return FileAccess.file_exists(get_mcp_json_path())


static func get_all_env_vars() -> Dictionary:
	var raw := _read_server_env()
	# Env vars are strings by definition. JSON may store them as integers
	# (e.g. "GODOT_MCP_READ_ONLY": 1 instead of "1"). Coerce all values
	# to String so consumers can safely compare with == "1" etc.
	var coerced: Dictionary = {}
	for key in raw:
		coerced[key] = str(raw[key])
	return coerced


## Parse .mcp.json WITHOUT spamming the console. JSON.parse_string() ERR_PRINTs on
## a malformed file ("Parse JSON failed. Error at line ..."), and the dock re-checks
## validity every ~1s — so use JSON.new().parse(), which reports failure via its
## return code silently. Returns the parsed object, or null if the file is missing /
## not valid JSON / not a JSON object.
static func _parse_mcp_json():
	var path := get_mcp_json_path()
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if _json.parse(text) != OK or not _json.data is Dictionary:
		return null
	return _json.data


static func _read_server_env() -> Dictionary:
	var parsed = _parse_mcp_json()
	if parsed == null:
		return {}
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return {}
	if not servers[server_key] is Dictionary:
		return {}
	var server_entry: Dictionary = servers[server_key]
	var env = server_entry.get("env", {})
	return env if env is Dictionary else {}


static func _find_server_key(servers: Dictionary) -> String:
	if servers.has("godot-mcp-toolkit"):
		return "godot-mcp-toolkit"
	for key in servers:
		if "godot-mcp" in str(key).to_lower():
			return str(key)
	return ""


## True iff .mcp.json sets GODOT_MCP_READ_ONLY=1 on the server entry.
## A shared query (dock panel + button, Info dialog) — one parse, one home.
## Callers that need it twice in a row cache the result (the dock does so
## per status refresh) rather than re-parsing.
static func is_read_only() -> bool:
	var env := get_all_env_vars()
	return env.get("GODOT_MCP_READ_ONLY", "") == "1"


## True iff .mcp.json exists but is NOT valid JSON (or not a JSON object) — the
## MCP client can't parse it, so it won't launch the server (and get_all_env_vars
## silently returns {}). A live FACT about the file's current content — safe to
## check on the dock's 1s timer like file presence, unlike read-only (server-state).
static func is_malformed() -> bool:
	return has_mcp_json() and _parse_mcp_json() == null


## True iff a .mcp.json already exists at the project root, so a write would
## overwrite it. The dock uses this to decide whether to show its overwrite
## confirmation dialog before calling write_from_template().
static func needs_overwrite_confirm() -> bool:
	return FileAccess.file_exists(get_mcp_json_path())


## Write .mcp.json from the bundled template, reporting the outcome through
## on_result so the UI (toast) stays dock-side. on_result is called once with:
##   (ok: bool, message: String, severity: int, tooltip: String)
## — severity matches the dock's _TOAST_* scale (0 info / 1 warning / 2 error);
## the dock forwards all four straight to its _toast(). Behaviour mirrors the
## former dock writer exactly: missing template -> error toast; existing file
## with force_overwrite == false -> a "needs confirm" report (defensive — the
## dock normally pre-checks via needs_overwrite_confirm()); otherwise copy the
## template and report success (info, with the destination as the tooltip) or
## the open failure (error). UI-free: no dialog, no EditorInterface, no _toast.
static func write_from_template(force_overwrite: bool, on_result: Callable) -> void:
	if not FileAccess.file_exists(_TEMPLATE_PATH):
		on_result.call(false, "Template not found: " + _TEMPLATE_PATH, 2, "")
		return
	var content := FileAccess.get_file_as_string(_TEMPLATE_PATH)
	var dest := get_mcp_json_path()
	if not force_overwrite and needs_overwrite_confirm():
		# Defensive: the dock should have shown its confirm dialog first. Report
		# without writing so no overwrite happens unconfirmed.
		on_result.call(false, ".mcp.json already exists — overwrite not confirmed", 1, dest)
		return
	_do_write(dest, content, on_result)


## Performs the actual copy of `content` to `dest` and reports via on_result.
## Private to the repository — the public entry point is write_from_template().
static func _do_write(dest: String, content: String, on_result: Callable) -> void:
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		on_result.call(
			false, "Failed to write .mcp.json (err %d)" % FileAccess.get_open_error(), 2, ""
		)
		return
	file.store_string(content)
	file.close()
	on_result.call(true, "MCP: .mcp.json created from template", 0, "Wrote to " + dest)
