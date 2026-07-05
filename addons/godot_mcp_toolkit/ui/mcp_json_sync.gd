@tool
extends RefCounted
## Repository for the project-root .mcp.json file.
##
## Owns all plugin access to .mcp.json: it reads (path resolution, the
## godot-mcp-toolkit server entry's env vars, read-only detection) AND builds
## the plugin-initiated write. The write is OS-aware — it emits a per-OS
## mcpServers command/args and, on macOS, resolves the user's real absolute
## node/npx path (plus a login-shell PATH backstop) so a Finder/Dock-launched
## MCP client finds Node despite launchd's minimal PATH. The file
## stays user-owned for edits; the plugin writes it on explicit user action (the
## dock's / Tools-menu's "Write .mcp.json") and refreshes an already-existing one
## on editor start to shrink the stale-after-node-switch window.
##
## UI-free by design: the write reports its outcome through an injected
## on_result Callable so the overwrite-confirmation dialog stays in the
## shared write flow and the feedback (toast) stays with each caller; this
## repository touches only the file and never reaches EditorInterface /
## a dialog / a toast.

# Direct preload (not via core/modules.gd): mcp_json_sync is itself aggregated by
# modules.gd, so reaching NodejsCheck through the aggregator would be a preload
# cycle. NodejsCheck owns the macOS login-shell probe used
# to resolve the real node path for the OS-aware emission.
const NodejsCheck := preload("res://addons/godot_mcp_toolkit/versioning/nodejs_check.gd")

# Bundled env/shape skeleton: the write reads its env block for the base env
# (GODOT_MCP_CONFIG_VERSION) and the per-OS builder overlays command/args/PATH.
const _TEMPLATE_PATH := "res://addons/godot_mcp_toolkit/.mcp.json.template"

# The mcpServers key the toolkit owns in .mcp.json.
const _SERVER_KEY := "godot-mcp-toolkit"

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
	return _extract_server_env(parsed)


## Navigate a parsed .mcp.json / template object to the toolkit server entry's env
## dict. Returns {} when there is no matching server entry or no env dict. Shared
## by the live-file read and the template-base read so the shape-walk lives once.
static func _extract_server_env(parsed: Dictionary) -> Dictionary:
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return {}
	if not servers[server_key] is Dictionary:
		return {}
	var server_entry: Dictionary = servers[server_key]
	var env = server_entry.get("env", {})
	return env if env is Dictionary else {}


## Navigate a parsed .mcp.json object to the toolkit server entry dict
## ({command, args, env}), or {} when there is no matching server entry. Sibling
## to [method _extract_server_env], which returns only the entry's env; this
## returns the whole entry so the startup refresh can field-compare command/args
## against a freshly-built entry (see [method needs_refresh]).
static func _extract_server_entry(parsed: Dictionary) -> Dictionary:
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return {}
	if not servers[server_key] is Dictionary:
		return {}
	return servers[server_key]


static func _find_server_key(servers: Dictionary) -> String:
	if servers.has(_SERVER_KEY):
		return _SERVER_KEY
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
## overwrite it. The shared write flow uses this to decide whether to show the
## overwrite confirmation dialog before calling write_from_template().
static func needs_overwrite_confirm() -> bool:
	return FileAccess.file_exists(get_mcp_json_path())


## Build the mcpServers server entry ({command, args, env}) for [param os_name] —
## the pure core of the OS-aware write. macOS emits option-d, an absolute node/npx
## path so a GUI-launched client bypasses launchd's PATH lookup:
## release pairs the absolute npx (derived beside [param resolved_node]) with the
## resolved PATH backstop; the dev form (when [param dev_server_path] is set) runs
## the absolute node against that dist entry — the strongest shape. When
## resolution failed ([param resolved_node] empty) it degrades to a bare npx/node
## command, recovered by the dock nudge + docs. Windows uses cmd /c npx (no
## launchd bug); Linux and any unknown OS use a bare npx/node. [param
## resolved_path] is the login-shell PATH (macOS only); the returned env carries
## only that builder-owned PATH backstop — the caller merges the template's base
## env (GODOT_MCP_CONFIG_VERSION).
static func build_server_entry(
	os_name: String, resolved_node: String, resolved_path: String, dev_server_path: String
) -> Dictionary:
	var is_dev := not dev_server_path.is_empty()
	var command := ""
	var args: Array = []
	match os_name:
		"macOS":
			if is_dev:
				# Absolute node dodges npx shebang re-resolution; bare node if unresolved.
				command = resolved_node if not resolved_node.is_empty() else "node"
				args = [dev_server_path]
			elif not resolved_node.is_empty():
				# Absolute npx sits beside the resolved node binary.
				command = resolved_node.get_base_dir() + "/npx"
				args = ["-y", _RELEASE_PACKAGE]
			else:
				command = "npx"
				args = ["-y", _RELEASE_PACKAGE]
		"Windows":
			# node is a real exe on PATH; npx is a .cmd shim that needs cmd /c.
			command = "node" if is_dev else "cmd"
			args = [dev_server_path] if is_dev else ["/c", "npx", "-y", _RELEASE_PACKAGE]
		_:
			# Linux and any unknown OS: no launchd bug, no shim — a bare command.
			command = "node" if is_dev else "npx"
			args = [dev_server_path] if is_dev else ["-y", _RELEASE_PACKAGE]
	var env: Dictionary = {}
	# macOS backstop for the npx-shebang gap: even an absolute npx can re-resolve
	# node from the (minimal launchd) PATH, so pass the real login-shell PATH.
	if os_name == "macOS" and not resolved_path.is_empty():
		env["PATH"] = resolved_path
	return {"command": command, "args": args, "env": env}


## Write .mcp.json for the current OS, reporting the outcome through on_result so
## the UI (toast) stays caller-side. on_result is called once with:
##   (ok: bool, message: String, severity: int, tooltip: String)
## — severity is the editor-toast scale (0 info / 1 warning / 2 error), which
## callers forward straight to their toast. Missing template -> error report;
## existing file with force_overwrite == false -> a "needs confirm" report
## (defensive — the shared write flow pre-checks via needs_overwrite_confirm());
## otherwise build the OS-aware content (see build_server_entry) and report
## success (info, with the destination as the tooltip) or the open failure
## (error). UI-free: no dialog, no EditorInterface, no toast.
static func write_from_template(force_overwrite: bool, on_result: Callable) -> void:
	if not FileAccess.file_exists(_TEMPLATE_PATH):
		on_result.call(false, "Template not found: " + _TEMPLATE_PATH, 2, "")
		return
	var dest := get_mcp_json_path()
	if not force_overwrite and needs_overwrite_confirm():
		# Defensive: the dock should have shown its confirm dialog first. Report
		# without writing so no overwrite happens unconfirmed.
		on_result.call(false, ".mcp.json already exists — overwrite not confirmed", 1, dest)
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
## GODOT_MCP_* keys (port pins, read-only, token/project paths) survive a rewrite,
## then the builder's own keys (the macOS PATH backstop) last. Pure — the three
## inputs are never mutated; [param existing_env] is {} for a first-time create.
## Returns the merged env for the server entry.
static func merge_server_env(
	base_env: Dictionary, existing_env: Dictionary, builder_env: Dictionary
) -> Dictionary:
	var env: Dictionary = base_env.duplicate()
	env.merge(existing_env, true)
	env.merge(builder_env, true)
	return env


## Build the OS-aware .mcp.json content — the full document string. Delegates the
## per-OS server entry to [method _build_entry] and wraps it (see
## [method _stringify_entry]).
static func _build_content() -> String:
	return _stringify_entry(_build_entry())


## Serialize a server entry as the complete .mcp.json document string (tab-indented,
## trailing newline). Shared by the full write and the startup field-compare refresh
## so the document shape lives once.
static func _stringify_entry(entry: Dictionary) -> String:
	var document := {"mcpServers": {_SERVER_KEY: entry}}
	return JSON.stringify(document, "\t") + "\n"


## Build the OS-aware server entry ({command, args, env}): resolve the real
## node/PATH on macOS, read the dev-server override, build the per-OS entry, and
## layer its env so an existing file's user keys are preserved (see merge_server_env).
static func _build_entry() -> Dictionary:
	var resolved := NodejsCheck.resolve_launch_paths()
	var resolved_node: String = str(resolved.get("node", ""))
	var resolved_path: String = str(resolved.get("path", ""))
	var dev_server_path := OS.get_environment(_DEV_SERVER_PATH_ENV)
	var entry := build_server_entry(OS.get_name(), resolved_node, resolved_path, dev_server_path)
	# Materialize each env read with duplicate() BEFORE the next read — the reads
	# share one JSON parser, so a later parse would invalidate an earlier returned
	# slice. The template base guarantees GODOT_MCP_CONFIG_VERSION; an existing
	# file's env is preserved so an automatic refresh never strips a user's
	# GODOT_MCP_* keys; the builder's PATH backstop overlays last.
	var base_env := _read_template_env().duplicate()
	var existing_env: Dictionary = {}
	if has_mcp_json():
		existing_env = _read_server_env().duplicate()
	var built_env: Dictionary = entry["env"]
	entry["env"] = merge_server_env(base_env, existing_env, built_env)
	return entry


## The bundled template's server-entry env dict (the write's base env), or {} when
## the template is missing / not valid JSON.
static func _read_template_env() -> Dictionary:
	var text := FileAccess.get_file_as_string(_TEMPLATE_PATH)
	if _json.parse(text) != OK or not _json.data is Dictionary:
		return {}
	return _extract_server_env(_json.data)


## True iff the automatic startup refresh should rewrite the file — i.e. a field
## the refresh owns (command, args, or env.PATH) differs between the existing file's
## server entry and a freshly-built one. Other env keys (a user's own GODOT_MCP_*
## pins) are preserved by [method merge_server_env] and never trigger a rewrite on
## their own, so a matching command/args/PATH means "no churn needed". Pure —
## neither argument is mutated.
static func needs_refresh(existing_entry: Dictionary, built_entry: Dictionary) -> bool:
	if str(existing_entry.get("command", "")) != str(built_entry.get("command", "")):
		return true
	# Variant-typed JSON slices → explicit typing, never := inference.
	var raw_existing_args = existing_entry.get("args", [])
	var raw_built_args = built_entry.get("args", [])
	var existing_args: Array = raw_existing_args if raw_existing_args is Array else []
	var built_args: Array = raw_built_args if raw_built_args is Array else []
	if existing_args != built_args:
		return true
	var raw_existing_env = existing_entry.get("env", {})
	var raw_built_env = built_entry.get("env", {})
	var existing_env: Dictionary = raw_existing_env if raw_existing_env is Dictionary else {}
	var built_env: Dictionary = raw_built_env if raw_built_env is Dictionary else {}
	return str(existing_env.get("PATH", "")) != str(built_env.get("PATH", ""))


## Refresh an already-configured .mcp.json in place at editor start so a macOS
## absolute node/npx path that went stale after a Node-version switch is re-resolved
## without the user clicking "Write". macOS-only: every other platform emits
## compile-time-constant commands (cmd /c npx on Windows, bare npx/node on Linux)
## with no absolute path to go stale, so the refresh is a pure no-op off macOS and
## never touches the file. Even on macOS it no-ops — never creates, never nags —
## when no file exists (a client isn't configured), the file is read-only (a
## deliberate security setting we must not silently strip) or malformed (mid-edit),
## or the freshly-built command/args/PATH already match (no churn; see
## [method needs_refresh]). Fire-and-forget.
static func refresh_existing_config() -> void:
	# Off macOS there is nothing to self-heal — skip before any file I/O or the
	# login-shell probe, so a Windows/Linux editor start never rewrites the file.
	if OS.get_name() != "macOS":
		return
	if not has_mcp_json():
		return
	if is_read_only() or is_malformed():
		return
	if not FileAccess.file_exists(_TEMPLATE_PATH):
		return
	# Build the fresh entry first (it fully materializes its env via duplicate()),
	# then parse the existing file — so the shared JSON parser can't invalidate the
	# built entry. Field-compare only what the refresh owns; matching = no churn.
	var built_entry := _build_entry()
	var parsed = _parse_mcp_json()
	var existing_entry: Dictionary = _extract_server_entry(parsed) if parsed != null else {}
	if not needs_refresh(existing_entry, built_entry):
		return
	var discard_result := func(_ok: bool, _msg: String, _sev: int, _tip: String) -> void:
		pass
	_do_write(get_mcp_json_path(), _stringify_entry(built_entry), discard_result)
