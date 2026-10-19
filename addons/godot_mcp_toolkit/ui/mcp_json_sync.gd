@tool
extends RefCounted
## Repository for the project-root .mcp.json file.
##
## Owns all plugin access to .mcp.json: it reads (path resolution, the
## godot-mcp-toolkit server entry's env vars, read-only detection, the server spec
## the entry runs) AND builds the plugin-initiated write. The write is OS-aware —
## it emits a per-OS mcpServers command/args (bare npx on macOS/Linux, cmd /c npx
## on Windows; a local server path emits the node form). The npx form pins the
## package to a version: the one this toolkit was tested with unless the project's
## [constant SERVER_VERSION_SETTING] asks for the newest release or another npm
## spec (see [method resolve_package_spec]). The file stays user-owned for edits;
## the plugin writes it only on explicit user action (the dock's / Tools-menu's
## "Write .mcp.json"). A write replaces only the toolkit's own server entry: it
## keeps the file's other servers and top-level keys and the existing entry's env
## keys, and it never replaces a file that is not valid JSON.
##
## UI-free by design: the write reports its outcome through an injected
## on_result Callable so the update-confirmation dialog stays in the
## shared write flow and the feedback (toast) stays with each caller; this
## repository touches only the file and never reaches EditorInterface /
## a dialog / a toast. Machine settings it needs (a local server path) are
## passed in by the editor-side callers.

const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The refusal reported when .mcp.json exists but is unusable (see [method
## is_malformed]): not a JSON object, or an mcpServers that is not one. Public so
## the write flow can show the same words in its dialog.
const MALFORMED_MESSAGE := ".mcp.json isn't valid JSON, or its mcpServers isn't an object — fix or delete it, then retry"

## The ProjectSettings key that picks the server version "Write .mcp.json" pins:
## empty for the version this toolkit was tested with, [constant LATEST_SETTING_VALUE]
## for the newest release, anything else as an npm version, range or tag. It is a
## team-shared choice, so it lives in project.godot.
const SERVER_VERSION_SETTING := "mcp_toolkit/server/version"

## The [constant SERVER_VERSION_SETTING] value (trimmed, any case) that asks for the
## newest server release.
const LATEST_SETTING_VALUE := "latest"

## Pin modes [method pin_mode] reports for a [constant SERVER_VERSION_SETTING] value.
const MODE_PINNED := "pinned"
const MODE_LATEST := "latest"
const MODE_CUSTOM := "custom"

## Server-spec classifications (see [method classify_server_entry]): an npx entry
## with no version, an npx entry with one ([constant SPEC_NPX_PREFIX] + the version
## part), a local build ([constant SPEC_LOCAL_PREFIX] + its path), or an entry that
## is none of those.
const SPEC_NPX_BARE := "npx-bare"
const SPEC_NPX_PREFIX := "npx:"
const SPEC_LOCAL_PREFIX := "local:"
const SPEC_UNKNOWN := "unknown"

## What [method nudge_state] says about the file's server spec: nothing to offer, a
## toolkit-written unversioned entry the pin would fix, a toolkit-written entry that
## no longer matches, or a spec someone set by hand.
const NUDGE_NONE := "none"
const NUDGE_UNPINNED := "unpinned"
const NUDGE_DIFFERS := "differs"
const NUDGE_FOREIGN := "foreign"

# Bundled env/shape skeleton: the write reads its env block for the base env
# (GODOT_MCP_CONFIG_VERSION, npm_config_prefer_offline); the per-OS builder
# overlays command/args.
const _TEMPLATE_PATH := "res://addons/godot_mcp_toolkit/.mcp.json.template"

# The mcpServers key the toolkit owns in .mcp.json.
const _SERVER_KEY := "godot-mcp-toolkit"

# The server's CLI name, as a global npm install puts it on PATH.
const _SERVER_BIN := "godot-mcp-server"

# Released npm package the client launches — the default (release) command base.
const _RELEASE_PACKAGE := "@npgamedev/godot-mcp-server"

# Optional env override: set to a local dist/index.js and the builder emits the
# dev form ([code]node <that path>[/code]) instead of the released npx form. The
# local-path editor setting wins over it; the path is read at build time, and no
# machine path is ever hardcoded here.
const _DEV_SERVER_PATH_ENV := "GODOT_MCP_DEV_SERVER_PATH"

# An env key the builder owns: npx reuses its cached package without asking the
# registry. Right for an exact version, which never changes once published; wrong
# for a range or tag, which it would freeze at whatever is cached.
const _PREFER_OFFLINE_ENV := "npm_config_prefer_offline"

# The success report of a write. A changed server spec means the client must
# restart to run it, and npx downloads it on that first launch.
const _WRITTEN_MESSAGE := "MCP: .mcp.json written"
const _WRITTEN_RESTART_MESSAGE := "MCP: .mcp.json written — restart your MCP client; the first launch after a version change downloads the server"

# Reused JSON parser — avoids allocating a JSON on every poll (the dock re-checks
# .mcp.json validity ~1s). Editor-only + main-thread, so one shared instance is
# safe; each parse() overwrites the prior data.
static var _json := JSON.new()

# An exact semver version with an optional prerelease, the only version part npm
# resolves to one fixed release.
static var _exact_version := RegEx.create_from_string("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z.-]+)?$")


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
## part, see [method resolve_package_spec]) via npx; the dev form (when [param
## dev_server_path] is set) runs node against that local dist entry, serving both
## Windows dogfooding and pointing at a local build. No env is emitted here — the
## caller supplies it (the template's base env plus an existing file's preserved
## keys).
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


## The pin mode a [constant SERVER_VERSION_SETTING] value selects: [constant
## MODE_PINNED] for an empty value, [constant MODE_LATEST] for [constant
## LATEST_SETTING_VALUE] (trimmed, any case), else [constant MODE_CUSTOM].
static func pin_mode(version_setting: String) -> String:
	var value := version_setting.strip_edges()
	if value.is_empty():
		return MODE_PINNED
	if value.to_lower() == LATEST_SETTING_VALUE:
		return MODE_LATEST
	return MODE_CUSTOM


## The npm package spec a write emits for [param version_setting] (the
## [constant SERVER_VERSION_SETTING] value): the package at [param compatible] when
## the setting is empty, at [code]latest[/code] when it asks for the newest, else at
## the setting's own value, trimmed and not validated (npm reports a bad spec when
## the client launches the server).
static func resolve_package_spec(version_setting: String, compatible: String) -> String:
	var mode := pin_mode(version_setting)
	if mode == MODE_PINNED:
		return _RELEASE_PACKAGE + "@" + compatible
	if mode == MODE_LATEST:
		return _RELEASE_PACKAGE + "@" + LATEST_SETTING_VALUE
	return _RELEASE_PACKAGE + "@" + version_setting.strip_edges()


## The local server path a write uses: [param local_path_setting] (the machine's
## editor setting) when it is set, else [param env_value] (the
## GODOT_MCP_DEV_SERVER_PATH environment variable), else "" for the npm package.
static func resolve_dev_server_path(local_path_setting: String, env_value: String) -> String:
	var setting := local_path_setting.strip_edges()
	return setting if not setting.is_empty() else env_value


## True iff [param package_spec]'s version part (after its last "@") is one exact
## semver version, prerelease allowed. A bare package name, a range or a tag is not.
static func is_exact_spec(package_spec: String) -> bool:
	var at := package_spec.rfind("@")
	if at <= 0:
		return false
	return _is_exact_version(package_spec.substr(at + 1))


## Return [param env] with the keys the builder owns set for the entry being
## written; they always win over the existing file's values. npm_config_prefer_offline
## is set to "true" for an exact [param package_spec] and removed for anything else,
## including a local build ([param dev_path] set), since it would freeze a range or
## tag at whatever npx has cached. Pure — [param env] is not mutated.
static func apply_owned_env(env: Dictionary, package_spec: String, dev_path: String) -> Dictionary:
	var owned: Dictionary = env.duplicate()
	if dev_path.is_empty() and is_exact_spec(package_spec):
		owned[_PREFER_OFFLINE_ENV] = "true"
	else:
		owned.erase(_PREFER_OFFLINE_ENV)
	return owned


## Classify the server a parsed mcpServers [param entry] runs: [constant
## SPEC_NPX_BARE] when its last arg is the package with no version, [constant
## SPEC_NPX_PREFIX] + the version part when it has one, [constant SPEC_LOCAL_PREFIX]
## + the path for [code]node <path>[/code], else [constant SPEC_UNKNOWN] (not an
## object, no args, or another command). The Windows [code]cmd /c npx[/code] and the
## bare [code]npx[/code] forms classify alike.
static func classify_server_entry(entry: Variant) -> String:
	if not entry is Dictionary:
		return SPEC_UNKNOWN
	var args_value: Variant = entry.get("args", [])
	if not args_value is Array or args_value.is_empty():
		return SPEC_UNKNOWN
	var args: Array = args_value
	match str(entry.get("command", "")):
		"node":
			return SPEC_LOCAL_PREFIX + str(args[0]) if args.size() == 1 else SPEC_UNKNOWN
		"npx", "cmd":
			return _classify_package_arg(str(args[args.size() - 1]))
	return SPEC_UNKNOWN


## True iff classifications [param a] and [param b] run the same server: equal, or
## one is the unversioned npx form and the other is npx at [code]latest[/code],
## which npx resolves alike.
static func same_spec(a: String, b: String) -> bool:
	if a == b:
		return true
	var newest := [SPEC_NPX_BARE, SPEC_NPX_PREFIX + LATEST_SETTING_VALUE]
	return a in newest and b in newest


## The classification a write would produce now: [constant SPEC_LOCAL_PREFIX] +
## [param dev_path] when a local server path is set, else that of the package spec
## [param version_setting] resolves to against [param compatible].
static func desired_classification(version_setting: String, compatible: String, dev_path: String) -> String:
	if not dev_path.is_empty():
		return SPEC_LOCAL_PREFIX + dev_path
	return _classify_package_arg(resolve_package_spec(version_setting, compatible))


## The classification of the server entry .mcp.json holds now (see [method
## classify_server_entry]), found the way the server finds its own entry; [constant
## SPEC_UNKNOWN] when the file is missing, malformed or has no such entry.
static func get_server_spec() -> String:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return SPEC_UNKNOWN
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_server_key(servers)
	if server_key.is_empty():
		return SPEC_UNKNOWN
	return classify_server_entry(servers[server_key])


## The classification a write would produce on this machine now (see [method
## desired_classification]): from the project's [constant SERVER_VERSION_SETTING],
## [param local_path_setting] (the machine's local server path setting, "" for
## none) and the GODOT_MCP_DEV_SERVER_PATH environment variable.
static func get_desired_spec(local_path_setting: String = "") -> String:
	return desired_classification(
			_read_version_setting(), VersionUtils.COMPATIBLE_SERVER_VERSION,
			_resolve_dev_path(local_path_setting))


## What to tell the user about the file's server spec [param on_disk], given
## [param last_written] (the spec this machine last wrote for the project, "" when
## none is recorded) and [param desired] (see [method desired_classification]).
## [constant NUDGE_NONE] when the file has no readable entry or already runs the
## desired server. A toolkit-written entry (it matches the record, or it is the
## unversioned form an older toolkit wrote before records existed) is [constant
## NUDGE_UNPINNED] when it floats and the desired spec is an exact version, else
## [constant NUDGE_DIFFERS]. Anything else was set by hand or by a teammate:
## [constant NUDGE_FOREIGN].
static func nudge_state(on_disk: String, last_written: String, desired: String) -> String:
	if on_disk == SPEC_UNKNOWN or same_spec(on_disk, desired):
		return NUDGE_NONE
	var toolkit_written := on_disk == last_written or (on_disk == SPEC_NPX_BARE and last_written.is_empty())
	if not toolkit_written:
		return NUDGE_FOREIGN
	var floating := same_spec(on_disk, SPEC_NPX_BARE)
	var desired_exact := (desired.begins_with(SPEC_NPX_PREFIX)
			and _is_exact_version(desired.substr(SPEC_NPX_PREFIX.length())))
	return NUDGE_UNPINNED if floating and desired_exact else NUDGE_DIFFERS


static func _classify_package_arg(arg: String) -> String:
	if arg == _RELEASE_PACKAGE:
		return SPEC_NPX_BARE
	if arg.begins_with(_RELEASE_PACKAGE + "@"):
		return SPEC_NPX_PREFIX + arg.substr(_RELEASE_PACKAGE.length() + 1)
	return SPEC_UNKNOWN


static func _is_exact_version(version: String) -> bool:
	return _exact_version.search(version) != null


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
## valid) receives (spec: String, changed: bool): the written entry's
## classification (see [method classify_server_entry]) and whether it differs from
## the entry the file held before.
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
	var previous_spec := _own_entry_spec()
	var entry := _build_entry(local_path_setting)
	var written_spec := classify_server_entry(entry)
	var error := _store(dest, _content_with(entry))
	if error != OK:
		on_result.call(false, "Failed to write .mcp.json (err %d)" % error, 2, "")
		return
	var changed := written_spec != previous_spec
	if on_written.is_valid():
		on_written.call(written_spec, changed)
	on_result.call(true, _WRITTEN_RESTART_MESSAGE if changed else _WRITTEN_MESSAGE, 0, "Wrote to " + dest)


## Writes [param content] to [param dest]. Returns OK, or the open error.
static func _store(dest: String, content: String) -> int:
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.close()
	return OK


## The classification of the file's own toolkit entry (see [method _find_own_key]),
## or [constant SPEC_UNKNOWN] when there is no file or no such entry.
static func _own_entry_spec() -> String:
	var parsed: Variant = _parse_mcp_json()
	if parsed == null:
		return SPEC_UNKNOWN
	var servers: Dictionary = parsed.get("mcpServers", {})
	var server_key := _find_own_key(servers)
	if server_key.is_empty():
		return SPEC_UNKNOWN
	return classify_server_entry(servers[server_key])


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
## environment variable) or the npm package spec the project's
## [constant SERVER_VERSION_SETTING] resolves to, the per-OS command/args, and the
## env layered so an existing file's user keys are preserved (see
## merge_server_env) with the builder-owned keys applied last (see
## apply_owned_env). Callable with no argument: that is the entry a machine with no
## local path setting writes.
static func _build_entry(local_path_setting: String = "") -> Dictionary:
	var dev_server_path := _resolve_dev_path(local_path_setting)
	var package_spec := resolve_package_spec(_read_version_setting(), VersionUtils.COMPATIBLE_SERVER_VERSION)
	var entry := build_server_entry(OS.get_name(), dev_server_path, package_spec)
	# The template base guarantees GODOT_MCP_CONFIG_VERSION; the file's own entry's
	# env is preserved so a rewrite never strips a user's GODOT_MCP_* keys. The
	# reads share one JSON parser, so each result is copied before the next read.
	var base_env := _read_template_env().duplicate()
	var existing_env := _read_own_env().duplicate()
	entry["env"] = apply_owned_env(
			merge_server_env(base_env, existing_env), package_spec, dev_server_path)
	return entry


## The project's [constant SERVER_VERSION_SETTING] value, "" when unset.
static func _read_version_setting() -> String:
	return str(ProjectSettings.get_setting(SERVER_VERSION_SETTING, ""))


## The local server path for [param local_path_setting], falling back to the
## GODOT_MCP_DEV_SERVER_PATH environment variable (see [method resolve_dev_server_path]).
static func _resolve_dev_path(local_path_setting: String) -> String:
	return resolve_dev_server_path(local_path_setting, OS.get_environment(_DEV_SERVER_PATH_ENV))


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
