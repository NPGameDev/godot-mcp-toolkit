@tool
extends RefCounted
## Thin lifecycle orchestrator + stable façade for the multi-instance registry.
##
## This is the public surface callers bind to (register / deregister /
## set_runtime / clear_runtime / ensure_registered, the runtime-port and
## LSP-endpoint read-backs, and the lock/dir pass-throughs). It owns sequencing
## only — the startup reap, the double-open warning, the write-then-lock-then-
## rebuild ordering, the deferred re-verify, and read-back composition. The "how"
## lives in the registry leaves it delegates to:
##   • ProjectKey       — the canonical project identity (path + 12-char hash)
##   • RegistryPaths    — the machine-wide registry dir and every file path
##   • RegistryEntryFile — atomic read/write/delete of one entry file + the builder
##   • RegistryProjection — fans the entry files in to the projects.json read model
##   • FileLock         — the advisory lock around each projection rebuild
##
## All methods are static — no instance state. Stays @tool and editor-clean
## (names zero Editor* symbols): it is in the runtime autoload's preload closure
## (mcp_runtime_server.gd), so an editor-tainted reference here would fail the
## autoload to parse in an export (godot#91713).

const _VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const FileLock := preload("res://addons/godot_mcp_toolkit/registry/store/file_lock.gd")
# Direct preload (NOT via core/modules.gd): this file is in the runtime autoload's
# preload closure (mcp_runtime_server.gd), so it must stay editor-clean — core/modules.gd
# names EditorInterface and would taint the autoload in exports (godot#91713).
const _ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")
# Direct preload (NOT via core/modules.gd): same runtime-closure cleanliness reason as
# above — RegistryPaths is editor-clean and owns the on-disk layout.
const _RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")
# Direct preload (NOT via core/modules.gd): same runtime-closure cleanliness reason —
# RegistryEntryFile is editor-clean and owns single-entry-file I/O + the builder.
const _RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry/store/registry_entry_file.gd")
# Direct preload (NOT via core/modules.gd): same runtime-closure cleanliness reason —
# RegistryProjection is editor-clean and builds the projects.json read model.
const _RegistryProjection := preload("res://addons/godot_mcp_toolkit/registry/store/registry_projection.gd")


# -- Path helpers (delegate to RegistryPaths — the layout authority) -----------


## Façade pass-through — external callers (unfocused_sleep_controller,
## extension_catalog) bind to RegistryClient.registry_dir().
static func registry_dir() -> String:
	return _RegistryPaths.registry_dir()


static func _project_key() -> String:
	return _ProjectKey.current()


static func _entry_file_path() -> String:
	return _RegistryPaths.entry_file_path()


static func _runtime_entry_file_path() -> String:
	return _RegistryPaths.runtime_entry_file_path()


# -- Lock file -----------------------------------------------------------------


## Public lock wrappers for callers that need to serialise a machine-wide
## read-modify-write on a sibling file in registry_dir() across concurrent
## editor instances (e.g. the unfocused-sleep backup — see mcp_server.gd /
## unfocused_backup.gd). Same lock as the registry's own writes, so backup and
## registry operations are mutually exclusive (both are rare and fast).
##
## These lock/dir wrappers stay on the registry façade deliberately: there is
## exactly ONE external lock client today (unfocused_sleep_controller, using just
## registry_dir + acquire_lock + release_lock), so a segregated lock role would be
## premature. If a 2nd non-registry lock client appears, extract a dedicated
## RegistryLock role (rule-of-three / ISP) and point both clients at it.
static func acquire_lock() -> bool:
	return FileLock.acquire(_RegistryPaths.lock_path())


static func release_lock() -> void:
	FileLock.release(_RegistryPaths.lock_path())


# -- Entry-file I/O (delegates to RegistryEntryFile — the I/O leaf) ------------


# Current-instance shorthands: bind this editor's entry path and delegate the
# atomic I/O to RegistryEntryFile. The lifecycle methods below sequence these.
static func _write_entry(entry: Dictionary) -> void:
	_RegistryEntryFile.write(_entry_file_path(), entry)


static func _read_entry() -> Dictionary:
	return _RegistryEntryFile.read(_entry_file_path())


static func _delete_entry() -> void:
	_RegistryEntryFile.delete(_entry_file_path())


# Build this instance's entry dict — delegate to the I/O leaf's pure builder.
static func _build_entry(key: String, port: int, token_path: String,
		lsp_host: String, lsp_port, runtime_port, runtime_pid) -> Dictionary:
	return _RegistryEntryFile.build_entry(
		key, port, token_path, lsp_host, lsp_port, runtime_port, runtime_pid)


# -- Projection rebuild (delegates to RegistryProjection — the read-model) -----


# Rebuild projects.json from all entry files. Delegates to RegistryProjection,
# the projection builder. The lifecycle methods below wrap this in
# acquire_lock()/release_lock() — the caller holds the lock (RegistryProjection
# assumes it, or accepts benign last-writer-wins).
static func _rebuild_projects_json() -> void:
	_RegistryProjection.rebuild()


# -- Lifecycle (public façade) -------------------------------------------------


static func register(port: int, token_path: String, lsp_host: String, lsp_port: int) -> void:
	# Startup reap: drop a stale <hash>.runtime.json left by a previous playtest
	# that crashed before clear_runtime() could fire — otherwise its dead
	# runtime_port would overlay this editor's entry until the next playtest
	# overwrites it. Safe to delete unconditionally here: register() runs only at
	# editor startup, and the sole writer of <hash>.runtime.json is this project's
	# playtest child, which dies with its parent editor and so cannot be alive now
	# (no concurrent RMW). An EXPORTED game's res:// hashes to a different file, so
	# this never touches it. OS.has_feature("editor") guards against a future stray
	# non-editor caller (runtime-safe, not editor-tainting).
	if OS.has_feature("editor"):
		_RegistryEntryFile.delete(_runtime_entry_file_path())
	var key := _project_key()
	var my_pid := OS.get_process_id()
	var my_entry := _build_entry(key, port, token_path, lsp_host, lsp_port, null, null)
	# Warn on double-open (same project in two editors).
	var existing := _read_entry()
	if not existing.is_empty():
		var existing_pid := int(existing.get("pid", 0))
		if existing_pid > 0 and existing_pid != my_pid and OS.is_process_running(existing_pid):
			push_warning("[MCPRegistry] already registered from PID %d; overwriting with PID %d" % [existing_pid, my_pid])
	# Write own entry file — no race: each editor writes a unique file.
	_write_entry(my_entry)
	# Rebuild projects.json from all entry files (idempotent).
	acquire_lock()
	_rebuild_projects_json()
	release_lock()
	print("[MCPRegistry] registered %s on port %d" % [key, port])


static func deregister() -> void:
	var key := _project_key()
	_delete_entry()
	acquire_lock()
	_rebuild_projects_json()
	release_lock()
	print("[MCPRegistry] deregistered %s" % key)


## Called from the runtime autoload (running game) when the Mode-B WS server
## binds. Writes the runtime's OWN entry file (<hash>.runtime.json) so it never
## read-modify-writes the editor's <hash>.json. The file is schema-complete on
## its own: when an editor entry exists, _rebuild_projects_json overlays only
## runtime_port/runtime_pid onto the editor base; when it doesn't, this file's
## full shape stands in (port -1, token_path "", lsp_port null — no editor was
## present to resolve an LSP endpoint, which the server reads as a miss).
static func set_runtime(runtime_port: int) -> void:
	var key := _project_key()
	var my_pid := OS.get_process_id()
	var entry := {
		"_key": key,
		"port": -1,
		"token_path": "",
		"pid": my_pid,
		"started_at": int(Time.get_unix_time_from_system()),
		"godot_version": _VersionUtils.get_engine_version_pair(),
		"runtime_port": runtime_port,
		"runtime_pid": my_pid,
		"lsp_host": "127.0.0.1",
		"lsp_port": null,
	}
	_RegistryEntryFile.write(_runtime_entry_file_path(), entry)
	acquire_lock()
	_rebuild_projects_json()
	release_lock()
	print("[MCPRegistry] runtime port %d registered for %s" % [runtime_port, key])


## Runtime counterpart to set_runtime — deletes the runtime's own file so the
## overlay disappears on the next rebuild. Touches only <hash>.runtime.json.
static func clear_runtime() -> void:
	var path := _runtime_entry_file_path()
	if not FileAccess.file_exists(path):
		return  # Already cleared / never set
	_RegistryEntryFile.delete(path)
	acquire_lock()
	_rebuild_projects_json()
	release_lock()


## Deferred re-verify: called a few seconds after initial register() to
## ensure our entry file still exists and projects.json is up to date.
## In the entry-file architecture this is mostly a rebuild trigger —
## our entry file can't be clobbered by another editor (unique path).
static func ensure_registered(port: int, token_path: String, lsp_host: String, lsp_port: int) -> void:
	var key := _project_key()
	var my_pid := OS.get_process_id()
	var entry := _read_entry()
	if not entry.is_empty() and int(entry.get("pid", 0)) == my_pid:
		# Entry file present with our PID — refresh the LSP endpoint (Q4 live
		# re-publish may pass a changed port/host) and rebuild projects.json.
		entry["lsp_host"] = lsp_host
		entry["lsp_port"] = lsp_port
		_write_entry(entry)
		acquire_lock()
		_rebuild_projects_json()
		release_lock()
		return
	# Entry file missing or wrong PID — re-create. The editor entry never carries
	# runtime fields (the runtime child owns <hash>.runtime.json), so pass null;
	# the runtime overlay re-applies on the next rebuild.
	push_warning("[MCPRegistry] entry file missing during deferred re-verify; re-creating for %s" % key)
	var new_entry := _build_entry(key, port, token_path, lsp_host, lsp_port, null, null)
	_write_entry(new_entry)
	acquire_lock()
	_rebuild_projects_json()
	release_lock()
	print("[MCPRegistry] re-registered %s on port %d (deferred)" % [key, port])


## Read-only: returns the runtime_port for this project, or -1. Reads the
## runtime child's own file (<hash>.runtime.json) — the runtime port lives
## there, not in the editor's <hash>.json.
static func get_runtime_port() -> int:
	var entry := _RegistryEntryFile.read(_runtime_entry_file_path())
	if entry.is_empty():
		return -1
	var rp = entry.get("runtime_port", null)
	if rp == null:
		return -1
	return int(rp)


## Read-only: this editor's published LSP endpoint as {host, port}, or {} when
## not yet published / unavailable. Backs the dock indicator (Fix 3). Pure.
static func get_lsp_endpoint() -> Dictionary:
	var entry := _read_entry()
	if entry.is_empty() or entry.get("lsp_port", null) == null:
		return {}
	return {
		"host": str(entry.get("lsp_host", "127.0.0.1")),
		"port": int(entry.get("lsp_port", 6005)),
	}
