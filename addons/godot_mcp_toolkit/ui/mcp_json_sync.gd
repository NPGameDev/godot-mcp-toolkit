@tool
extends RefCounted
## Repository for the project-root .mcp.json file.
##
## Owns all plugin access to .mcp.json: it reads (path resolution, the
## godot-mcp-toolkit server entry's env vars, read-only detection, the server spec
## the entry runs) AND builds the plugin-initiated write. The write is OS-aware —
## it emits a per-OS mcpServers command/args (bare npx on macOS/Linux, cmd /c npx
## on Windows; a local server path emits the node form). The npx form runs the
## package spec the server pin policy picks from the project's version setting
## ([code]ui/mcp_json/server_pin_policy.gd[/code]). The file stays user-owned for
## edits; the plugin writes it only on explicit user action (the dock's /
## Tools-menu's "Write .mcp.json"). A write replaces only the toolkit's own server
## entry: it keeps the file's other servers and top-level keys and the existing
## entry's env keys, and it never replaces a file that is not valid JSON.
##
## UI-free by design: the write reports its outcome through an injected
## on_result Callable so the update-confirmation dialog stays in the
## shared write flow and the feedback (toast) stays with each caller; this
## repository never reaches EditorInterface / a dialog / a toast. It writes only
## .mcp.json: it reads the project's server version setting through the pin policy,
## which owns that setting's save to project.godot. Machine settings it needs (a
## local server path) are passed in by the editor-side callers.

const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")

## The refusal reported when .mcp.json exists but is unusable (see [method
## is_malformed]): not a JSON object, or an mcpServers that is not one. Public so
## the write flow can show the same words in its dialog.
const MALFORMED_MESSAGE := ".mcp.json isn't valid JSON, or its mcpServers isn't an object — fix or delete it, then retry"

# Bundled env/shape skeleton: the write reads its env block for the base env
# (GODOT_MCP_CONFIG_VERSION, npm_config_prefer_offline); the per-OS builder
# overlays command/args.
const _TEMPLATE_PATH := "res://addons/godot_mcp_toolkit/.mcp.json.template"

# The mcpServers key the toolkit owns in .mcp.json.
const _SERVER_KEY := "godot-mcp-toolkit"

# The server's CLI name, as a global npm install puts it on PATH.
const _SERVER_BIN := "godot-mcp-server"

# Optional env override: set to a local dist/index.js and the builder emits the
# dev form ([code]node <that path>[/code]) instead of the released npx form. The
# local-path editor setting wins over it; the path is read at build time, and no
# machine path is ever hardcoded here.
const _DEV_SERVER_PATH_ENV := "GODOT_MCP_DEV_SERVER_PATH"

# An env key the builder owns: npx reuses its cached package without asking the
# registry. Right for an exact version, which never changes once published; wrong
# for a range or tag, which it would freeze at whatever is cached.
const _PREFER_OFFLINE_ENV := "npm_config_prefer_offline"

# An env key the builder owns: the server skips its connect-time version check. Set
# only for a local server build, whose version says nothing about the wire contract
# it speaks; keyed to the local path setting, never to the entry's shape.
const _SKIP_VERSION_CHECK_ENV := "GODOT_MCP_SKIP_VERSION_CHECK"

# The success report of a write. A changed server spec means the client must
# restart to run it, and npx downloads it on that first launch.
const _WRITTEN_MESSAGE := "MCP: .mcp.json written"
const _WRITTEN_RESTART_MESSAGE := "MCP: .mcp.json written — restart your MCP client; the first launch after a version change downloads the server"

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
			if str(arg).contains(ServerPinPolicy.RELEASE_PACKAGE):
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
## differs from the one the write would emit for [param local_path_setting] (the
## machine's local server path setting, "" for none). No file, no toolkit entry and
## an identical entry need no confirm (nothing the user has is lost); a malformed
## file is refused outright by write_from_template(), so it is not a confirm case
## either. The shared write flow uses this to decide whether to show the update
## confirmation dialog before calling write_from_template().
static func needs_overwrite_confirm(local_path_setting: String = "") -> bool:
	var existing: Variant = _parse_mcp_json()
	if existing == null:
		return false
	var servers: Dictionary = existing.get("mcpServers", {})
	var server_key := _find_own_key(servers)
	if server_key.is_empty():
		return false
	var current := _stringify_canonical(servers[server_key])
	return current != _stringify_canonical(_build_entry(local_path_setting))


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
## form runs [param package_spec] (the package name, with or without a version
## part, see [code]ServerPinPolicy.resolve_package_spec[/code]) via npx; the dev
## form (when [param dev_server_path] is set) runs node against that local dist
## entry, serving both Windows dogfooding and pointing at a local build. No env is
## emitted here — the caller supplies it (the template's base env plus an existing
## file's preserved keys).
static func build_server_entry(os_name: String, dev_server_path: String, package_spec: String) -> Dictionary:
	var is_dev := not dev_server_path.is_empty()
	var command := ""
	var args: Array = []
	match os_name:
		"Windows":
			# node is a real exe on PATH; npx is a .cmd shim that needs cmd /c.
			command = "node" if is_dev else "cmd"
			args = [dev_server_path] if is_dev else ["/c", "npx", "-y", package_spec]
		_:
			# macOS, Linux, and any unknown OS: no shim — a bare command. A GUI-launched
			# client resolves bare npx to a version-manager node via its captured shell env.
			command = "node" if is_dev else "npx"
			args = [dev_server_path] if is_dev else ["-y", package_spec]
	return {"command": command, "args": args}


## The local server path a write uses: [param local_path_setting] (the machine's
## editor setting) when it is set, else [param env_value] (the
## GODOT_MCP_DEV_SERVER_PATH environment variable), else "" for the npm package.
static func resolve_dev_server_path(local_path_setting: String, env_value: String) -> String:
	var setting := local_path_setting.strip_edges()
	return setting if not setting.is_empty() else env_value


## Return [param env] with the keys the builder owns set for the entry being
## written; they always win over the existing file's values. npm_config_prefer_offline
## is set to "true" for an exact [param package_spec] and removed for anything else,
## including a local build ([param dev_path] set), since it would freeze a range or
## tag at whatever npx has cached. GODOT_MCP_SKIP_VERSION_CHECK is set to "1" for a
## local build and removed otherwise. Pure — [param env] is not mutated.
static func apply_owned_env(env: Dictionary, package_spec: String, dev_path: String) -> Dictionary:
	var owned: Dictionary = env.duplicate()
	if dev_path.is_empty() and ServerPinPolicy.is_exact_spec(package_spec):
		owned[_PREFER_OFFLINE_ENV] = "true"
	else:
		owned.erase(_PREFER_OFFLINE_ENV)
	if dev_path.is_empty():
		owned.erase(_SKIP_VERSION_CHECK_ENV)
	else:
		owned[_SKIP_VERSION_CHECK_ENV] = "1"
	return owned


## The classification of the server entry .mcp.json holds now (see
## [code]ServerPinPolicy.classify_server_entry[/code]), found the way the server
## finds its own entry; [code]ServerPinPolicy.SPEC_UNKNOWN[/code] when the file is
## missing, malformed or has no such entry.
static func get_server_spec() -> String:
	return ServerPinPolicy.classify_server_entry(_read_file_entry(false))


## The file's state from one parse, for a caller that polls it: {present, malformed,
## spec}. [code]present[/code] and [code]malformed[/code] are [method has_mcp_json]
## and [method is_malformed]; [code]spec[/code] is [method get_server_spec], or
## [code]ServerPinPolicy.SPEC_UNKNOWN[/code] while the file is missing or malformed.
static func read_file_state() -> Dictionary:
	var state := {"present": has_mcp_json(), "malformed": false, "spec": ServerPinPolicy.SPEC_UNKNOWN}
	if not state["present"]:
		return state
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		state["malformed"] = true
		return state
	state["spec"] = ServerPinPolicy.classify_server_entry(_entry_in(parsed, false))
	return state


## The classification a write would produce on this machine now (see
## [code]ServerPinPolicy.desired_classification[/code]): from the project's server
## version setting, [param local_path_setting] (the machine's local server path
## setting, "" for none) and the GODOT_MCP_DEV_SERVER_PATH environment variable.
static func get_desired_spec(local_path_setting: String = "") -> String:
	return ServerPinPolicy.desired_classification(
			ServerPinPolicy.read_version_setting(), VersionUtils.COMPATIBLE_SERVER_VERSION,
			resolve_machine_dev_path(local_path_setting))


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
## failure (error). The success message asks for a client restart when the server
## spec changed. UI-free: no dialog, no EditorInterface, no toast.
##
## [param local_path_setting] is the machine's local server path setting ("" for
## none). After a successful write and before on_result, [param on_written] (when
## valid) receives (spec: String): the written entry's classification (see
## [code]ServerPinPolicy.classify_server_entry[/code]).
static func write_from_template(
		force_overwrite: bool, on_result: Callable,
		local_path_setting: String = "", on_written: Callable = Callable()) -> void:
	if not FileAccess.file_exists(_TEMPLATE_PATH):
		on_result.call(false, "Template not found: " + _TEMPLATE_PATH, 2, "")
		return
	var dest := get_mcp_json_path()
	if is_malformed():
		on_result.call(false, MALFORMED_MESSAGE, 1, dest)
		return
	if not force_overwrite and needs_overwrite_confirm(local_path_setting):
		# Defensive: the write flow should have shown its confirm dialog first.
		# Report without writing so no change happens unconfirmed.
		on_result.call(false, ".mcp.json already has a different entry — update not confirmed", 1, dest)
		return
	var previous_spec := ServerPinPolicy.classify_server_entry(_read_file_entry(true))
	var entry := _build_entry(local_path_setting)
	var written_spec := ServerPinPolicy.classify_server_entry(entry)
	var error := _store(dest, _content_with(entry))
	if error != OK:
		on_result.call(false, "Failed to write .mcp.json (err %d)" % error, 2, "")
		return
	var changed := written_spec != previous_spec
	if on_written.is_valid():
		on_written.call(written_spec)
	on_result.call(true, _WRITTEN_RESTART_MESSAGE if changed else _WRITTEN_MESSAGE, 0, "Wrote to " + dest)


## Writes [param content] to [param dest]. Returns OK, or the open error.
static func _store(dest: String, content: String) -> int:
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


## The toolkit's server entry in .mcp.json as parsed, or null when the file is
## missing or malformed or has no such entry. [param own_entry_only] picks the key
## match: the strict [method _find_own_key] a write uses, else the loose
## [method _find_server_key] that mirrors the server's own read.
static func _read_file_entry(own_entry_only: bool) -> Variant:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return null
	return _entry_in(parsed, own_entry_only)


## The toolkit's server entry in a parsed [param document] (see [method
## _read_file_entry] for [param own_entry_only]), or null when it has none.
static func _entry_in(document: Dictionary, own_entry_only: bool) -> Variant:
	var servers: Dictionary = document.get("mcpServers", {})
	var server_key := _find_own_key(servers) if own_entry_only else _find_server_key(servers)
	if server_key.is_empty():
		return null
	return servers[server_key]


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


## Build the OS-aware .mcp.json content — the full document string — for
## [param local_path_setting] (see [method _build_entry]).
static func _build_content(local_path_setting: String = "") -> String:
	return _content_with(_build_entry(local_path_setting))


## The full document string with [param entry] replacing the existing file's
## toolkit entry (under that entry's own key, see [method _find_own_key], else
## [constant _SERVER_KEY]) inside the file's parsed document, so the rest of a
## shared file survives the rewrite.
static func _content_with(entry: Dictionary) -> String:
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


## Build the OS-aware server entry ({command, args, env}) a write emits: the local
## server path ([param local_path_setting], else the GODOT_MCP_DEV_SERVER_PATH
## environment variable) or the npm package spec the project's server version
## setting resolves to (see [code]ServerPinPolicy.resolve_package_spec[/code]), the
## per-OS command/args, and the env layered so an existing file's user keys are
## preserved (see merge_server_env) with the builder-owned keys applied last (see
## apply_owned_env). Callable with no argument: that is the entry a machine with no
## local path setting writes.
static func _build_entry(local_path_setting: String = "") -> Dictionary:
	var dev_server_path := resolve_machine_dev_path(local_path_setting)
	var package_spec := ServerPinPolicy.resolve_package_spec(
			ServerPinPolicy.read_version_setting(), VersionUtils.COMPATIBLE_SERVER_VERSION)
	var entry := build_server_entry(OS.get_name(), dev_server_path, package_spec)
	# The template base guarantees GODOT_MCP_CONFIG_VERSION; the file's own entry's
	# env is preserved so a rewrite never strips a user's GODOT_MCP_* keys. The
	# reads share one JSON parser, so each result is copied before the next read.
	var base_env := _read_template_env().duplicate()
	var existing_env := _read_own_env().duplicate()
	entry["env"] = apply_owned_env(
			merge_server_env(base_env, existing_env), package_spec, dev_server_path)
	return entry


## The local server path for [param local_path_setting], falling back to the
## GODOT_MCP_DEV_SERVER_PATH environment variable (see [method resolve_dev_server_path]).
static func resolve_machine_dev_path(local_path_setting: String) -> String:
	return resolve_dev_server_path(local_path_setting, OS.get_environment(_DEV_SERVER_PATH_ENV))


## The env dict of the toolkit's own entry in .mcp.json (see [method _find_own_key]),
## or {} when there is no file, no such entry or no env.
static func _read_own_env() -> Dictionary:
	return _entry_env(_read_file_entry(true))


## The bundled template's server-entry env dict (the write's base env), or {} when
## the template is missing / not valid JSON.
static func _read_template_env() -> Dictionary:
	var text := FileAccess.get_file_as_string(_TEMPLATE_PATH)
	if _json.parse(text) != OK or not _json.data is Dictionary:
		return {}
	return _extract_server_env(_json.data)
