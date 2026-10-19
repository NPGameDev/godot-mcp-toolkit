@tool
extends RefCounted
## Repository for the project-root .mcp.json file.
##
## Owns all plugin access to .mcp.json: it reads (path resolution, the
## godot-mcp-toolkit server entry's env vars, read-only detection) AND builds
## the plugin-initiated write. The write is OS-aware — it emits a per-OS
## mcpServers command/args (bare npx on macOS/Linux, cmd /c npx on Windows; a
## GODOT_MCP_DEV_SERVER_PATH override emits the local-dist node form). The file
## stays user-owned for edits; the plugin writes it only on explicit user action
## (the dock's / Tools-menu's "Write .mcp.json"). A write replaces only the
## toolkit's own server entry: it keeps the file's other servers and top-level
## keys and the existing entry's GODOT_MCP_* env keys, and it never replaces a
## file that is not valid JSON.
##
## UI-free by design: the write reports its outcome through an injected
## on_result Callable so the update-confirmation dialog stays in the
## shared write flow and the feedback (toast) stays with each caller; this
## repository touches only the file and never reaches EditorInterface /
## a dialog / a toast.

# Bundled env/shape skeleton: the write reads its env block for the base env
# (GODOT_MCP_CONFIG_VERSION); the per-OS builder overlays command/args.
const _TEMPLATE_PATH := "res://addons/godot_mcp_toolkit/.mcp.json.template"

## The refusal reported when .mcp.json exists but is unusable (see [method
## is_malformed]): not a JSON object, or an mcpServers that is not one. Public so
## the write flow can show the same words in its dialog.
const MALFORMED_MESSAGE := ".mcp.json isn't valid JSON, or its mcpServers isn't an object — fix or delete it, then retry"

# The mcpServers key the toolkit owns in .mcp.json.
const _SERVER_KEY := "godot-mcp-toolkit"

# The server's CLI name, as a global npm install puts it on PATH.
const _SERVER_BIN := "godot-mcp-server"

# Released npm package the client launches — the default (release) command base.
const _RELEASE_PACKAGE := "@npgamedev/godot-mcp-server"

# Optional env override: set to a local dist/index.js and the builder emits the
# dev form ([code]node <that path>[/code]) instead of the released npx form — one
# path serving Windows dogfooding and pointing a Mac at a local build. The path is
# read from the environment at build time; no machine path is ever hardcoded here.
const _DEV_SERVER_PATH_ENV := "GODOT_MCP_DEV_SERVER_PATH"

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
## not valid JSON / not a JSON object / has an [code]mcpServers[/code] value that is
## not an object (a client can't read that shape either).
static func _parse_mcp_json():
	var path := get_mcp_json_path()
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if _json.parse(text) != OK or not _json.data is Dictionary:
		return null
	var document: Dictionary = _json.data
	if document.has("mcpServers") and not document["mcpServers"] is Dictionary:
		return null
	return document


static func _read_server_env() -> Dictionary:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return {}
	return _extract_server_env(parsed)


## Navigate a parsed .mcp.json / template object to the toolkit server entry's env
## dict. Returns {} when there is no matching server entry or no env dict. Shared
## by the live-file read and the template-base read so the shape-walk lives once.
## The key match is the loose [method _find_server_key] one, mirroring the server's
## own read of the file.
static func _extract_server_env(parsed: Dictionary) -> Dictionary:
	var servers_value: Variant = parsed.get("mcpServers", {})
	if not servers_value is Dictionary:
		return {}
	var servers: Dictionary = servers_value
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return {}
	return _entry_env(servers[server_key])


## The env dict of one server entry, or {} when the entry or its env is not an object.
static func _entry_env(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {}
	var env: Variant = entry.get("env", {})
	return env if env is Dictionary else {}


## The key of the first server whose name looks like the toolkit's. Loose on
## purpose: it serves the reads (read-only detection, env), which must match how
## the server finds its own entry. A write uses [method _find_own_key] instead.
static func _find_server_key(servers: Dictionary) -> String:
	if servers.has(_SERVER_KEY):
		return _SERVER_KEY
	for key in servers:
		if "godot-mcp" in str(key).to_lower():
			return str(key)
	return ""


## The key of the toolkit's own entry in [param servers], for a write: the default
## key, else a "godot-mcp" key whose entry is recognisably ours (see
## [method _is_own_entry]). A foreign server that merely has "godot-mcp" in its
## name is not ours, so a write leaves it alone. "" when there is none.
static func _find_own_key(servers: Dictionary) -> String:
	if servers.has(_SERVER_KEY):
		return _SERVER_KEY
	for key in servers:
		if "godot-mcp" in str(key).to_lower() and _is_own_entry(servers[key]):
			return str(key)
	return ""


## True iff [param entry] is one the toolkit wrote or a global install of the
## server would be: its args name the released package, its command is the
## [code]godot-mcp-server[/code] binary, or its env carries the template's
## GODOT_MCP_CONFIG_VERSION marker (which the dev-server form has too).
static func _is_own_entry(entry: Variant) -> bool:
	if not entry is Dictionary:
		return false
	if str(entry.get("command", "")).contains(_SERVER_BIN):
		return true
	var args: Variant = entry.get("args", [])
	if args is Array:
		for arg in args:
			if str(arg).contains(_RELEASE_PACKAGE):
				return true
	return _entry_env(entry).has("GODOT_MCP_CONFIG_VERSION")


## True iff .mcp.json sets GODOT_MCP_READ_ONLY=1 on the server entry.
## A shared query (dock panel + button, Info dialog) — one parse, one home.
## Callers that need it twice in a row cache the result (the dock does so
## per status refresh) rather than re-parsing.
static func is_read_only() -> bool:
	var env := get_all_env_vars()
	return env.get("GODOT_MCP_READ_ONLY", "") == "1"


## True iff .mcp.json exists but is NOT valid JSON, is not a JSON object, or has an
## [code]mcpServers[/code] value that is not an object — the MCP client can't use
## it, so it won't launch the server (and get_all_env_vars silently returns {}).
## A live FACT about the file's current content — safe to
## check on the dock's 1s timer like file presence, unlike read-only (server-state).
static func is_malformed() -> bool:
	return has_mcp_json() and _parse_mcp_json() == null


## True iff a write would change an entry the user already has: the file parses,
## holds a toolkit server entry (see [method _find_own_key]), and that entry
## differs from the one the write would emit. No file, no toolkit entry and an
## identical entry need no confirm (nothing the user has is lost); a malformed
## file is refused outright by write_from_template(), so it is not a confirm case
## either. The shared write flow uses this to decide whether to show the update
## confirmation dialog before calling write_from_template().
static func needs_overwrite_confirm() -> bool:
	var existing: Variant = _parse_mcp_json()
	if existing == null:
		return false
	var servers: Dictionary = existing.get("mcpServers", {})
	var server_key := _find_own_key(servers)
	if server_key.is_empty():
		return false
	return _stringify_canonical(servers[server_key]) != _stringify_canonical(_build_entry())


## The mcpServers key a write would put the toolkit's entry under: the key of the
## file's own entry (see [method _find_own_key]), else the default key.
static func get_own_entry_key() -> String:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return _SERVER_KEY
	return _own_key_in(parsed)


static func _own_key_in(document: Dictionary) -> String:
	var servers: Dictionary = document.get("mcpServers", {})
	var found_key := _find_own_key(servers)
	return _SERVER_KEY if found_key.is_empty() else found_key


## Build the mcpServers server entry ({command, args}) for [param os_name] — the
## pure core of the OS-aware write. macOS and Linux emit a bare npx (release) or
## node (dev); Windows uses cmd /c npx (npx is a .cmd shim there). The release
## form runs the published package via npx; the dev form (when [param
## dev_server_path] is set) runs node against that local dist entry, serving both
## Windows dogfooding and pointing at a local build. No env is emitted here — the
## caller supplies it (the template's GODOT_MCP_CONFIG_VERSION plus an existing
## file's preserved GODOT_MCP_* keys).
static func build_server_entry(os_name: String, dev_server_path: String) -> Dictionary:
	var is_dev := not dev_server_path.is_empty()
	var command := ""
	var args: Array = []
	match os_name:
		"Windows":
			# node is a real exe on PATH; npx is a .cmd shim that needs cmd /c.
			command = "node" if is_dev else "cmd"
			args = [dev_server_path] if is_dev else ["/c", "npx", "-y", _RELEASE_PACKAGE]
		_:
			# macOS, Linux, and any unknown OS: no shim — a bare command. A GUI-launched
			# client resolves bare npx to a version-manager node via its captured shell env.
			command = "node" if is_dev else "npx"
			args = [dev_server_path] if is_dev else ["-y", _RELEASE_PACKAGE]
	return {"command": command, "args": args}


## Write .mcp.json for the current OS, reporting the outcome through on_result so
## the UI (toast) stays caller-side. on_result is called once with:
##   (ok: bool, message: String, severity: int, tooltip: String)
## — severity is the editor-toast scale (0 info / 1 warning / 2 error), which
## callers forward straight to their toast. Missing template -> error report;
## an existing file that is_malformed() -> a refusal report, even with
## force_overwrite (a malformed file is never replaced, so nothing it holds is
## lost); a changed toolkit entry with force_overwrite == false -> a "needs
## confirm" report (defensive — the shared write flow pre-checks via
## needs_overwrite_confirm()); otherwise build the OS-aware content (see
## build_server_entry and merge_document — every other server and top-level key is
## kept) and report success (info, with the destination as the tooltip) or the open
## failure (error). UI-free: no dialog, no EditorInterface, no toast.
static func write_from_template(force_overwrite: bool, on_result: Callable) -> void:
	if not FileAccess.file_exists(_TEMPLATE_PATH):
		on_result.call(false, "Template not found: " + _TEMPLATE_PATH, 2, "")
		return
	var dest := get_mcp_json_path()
	if is_malformed():
		on_result.call(false, MALFORMED_MESSAGE, 1, dest)
		return
	if not force_overwrite and needs_overwrite_confirm():
		# Defensive: the write flow should have shown its confirm dialog first.
		# Report without writing so no change happens unconfirmed.
		on_result.call(false, ".mcp.json already has a different entry — update not confirmed", 1, dest)
		return
	_do_write(dest, _build_content(), on_result)


## Performs the actual write of `content` to `dest` and reports via on_result.
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
	on_result.call(true, "MCP: .mcp.json written", 0, "Wrote to " + dest)


## Layer the emitted server env, most-general first: the template's base env
## (GODOT_MCP_CONFIG_VERSION), then an EXISTING file's env so a user's own
## GODOT_MCP_* keys (port pins, read-only, token/project paths) survive a rewrite.
## Pure — neither input is mutated; [param existing_env] is {} for a first-time
## create. Returns the merged env for the server entry.
static func merge_server_env(base_env: Dictionary, existing_env: Dictionary) -> Dictionary:
	var env: Dictionary = base_env.duplicate()
	env.merge(existing_env, true)
	return env


## Return [param existing] with the [param server_key] entry set to [param entry]:
## every other server and top-level key is kept as parsed, and [code]mcpServers[/code]
## is created when missing. Pure — [param existing] is not mutated; the untouched
## servers are shared with the copy, not deep-copied.
static func merge_document(existing: Dictionary, server_key: String, entry: Dictionary) -> Dictionary:
	var document: Dictionary = existing.duplicate()
	var servers: Dictionary = {}
	var existing_servers: Variant = existing.get("mcpServers")
	if existing_servers is Dictionary:
		servers = existing_servers.duplicate()
	servers[server_key] = entry
	document["mcpServers"] = servers
	return document


## Build the OS-aware .mcp.json content — the full document string. The server
## entry comes from [method _build_entry]; it replaces the existing file's toolkit
## entry (under that entry's own key, see [method _find_own_key], else
## [constant _SERVER_KEY]) inside the file's parsed document, so the rest of a
## shared file survives the rewrite.
static func _build_content() -> String:
	var entry := _build_entry()
	# The copy is deep so the document owns its data apart from the shared parser.
	var existing_document: Dictionary = {}
	var parsed: Variant = _parse_mcp_json()
	if parsed is Dictionary:
		existing_document = parsed.duplicate(true)
	var server_key := _own_key_in(existing_document)
	return _stringify_document(merge_document(existing_document, server_key, entry))


## Serialize a document as the complete .mcp.json string (tab-indented, trailing
## newline). Keys keep their order and numbers are written at full precision, so a
## user's file is not reordered and its number values are kept.
static func _stringify_document(document: Dictionary) -> String:
	return JSON.stringify(document, "\t", false, true) + "\n"


## Stable string form of a value for comparing two parsed JSON values by content.
static func _stringify_canonical(value: Variant) -> String:
	return JSON.stringify(value, "", true, true)


## Build the OS-aware server entry ({command, args, env}): read the dev-server
## override, build the per-OS command/args, and layer the env so an existing
## file's user keys are preserved (see merge_server_env).
static func _build_entry() -> Dictionary:
	var dev_server_path := OS.get_environment(_DEV_SERVER_PATH_ENV)
	var entry := build_server_entry(OS.get_name(), dev_server_path)
	# The template base guarantees GODOT_MCP_CONFIG_VERSION; the file's own entry's
	# env is preserved so a rewrite never strips a user's GODOT_MCP_* keys. The
	# reads share one JSON parser, so each result is copied before the next read.
	var base_env := _read_template_env().duplicate()
	var existing_env := _read_own_env().duplicate()
	entry["env"] = merge_server_env(base_env, existing_env)
	return entry


## The env dict of the toolkit's own entry in .mcp.json (see [method _find_own_key]),
## or {} when there is no file, no such entry or no env.
static func _read_own_env() -> Dictionary:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return {}
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_own_key(servers)
	if server_key.is_empty():
		return {}
	return _entry_env(servers[server_key])


## The bundled template's server-entry env dict (the write's base env), or {} when
## the template is missing / not valid JSON.
static func _read_template_env() -> Dictionary:
	var text := FileAccess.get_file_as_string(_TEMPLATE_PATH)
	if _json.parse(text) != OK or not _json.data is Dictionary:
		return {}
	return _extract_server_env(_json.data)
