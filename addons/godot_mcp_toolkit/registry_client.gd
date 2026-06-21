@tool
extends RefCounted
## System-wide project registry for multi-project concurrency.
##
## Each Godot editor writes its own entry file under entries/<hash>.json; the
## editor's runtime child (the running game) writes its OWN entries/<hash>.runtime.json.
## _rebuild_projects_json() aggregates all entry files into projects.json — merging
## the runtime overlay onto the editor base by _key — so the TypeScript bridge can
## discover all active editors and their live runtime ports.
##
## One writer per file: distinct projects, and the editor vs its runtime child,
## each own a separate file — so there is no shared read-modify-write anywhere.
## Concurrent rebuilds are idempotent (same entry files → same output).
##
## All methods are static — no instance state. Callers preload via
## _hub.gd (RegistryClient) or directly.

const _VersionUtils := preload("res://addons/godot_mcp_toolkit/mcp_version_utils.gd")
const FileLock := preload("res://addons/godot_mcp_toolkit/file_lock.gd")
# Direct preload (NOT via _hub.gd): this file is in the runtime autoload's
# preload closure (mcp_runtime_server.gd), so it must stay editor-clean — _hub.gd
# names EditorInterface and would taint the autoload in exports (godot#91713).
const _ProjectKey := preload("res://addons/godot_mcp_toolkit/project_key.gd")
# Direct preload (NOT via _hub.gd): same runtime-closure cleanliness reason as
# above — RegistryPaths is editor-clean and owns the on-disk layout.
const _RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry_paths.gd")
# Direct preload (NOT via _hub.gd): same runtime-closure cleanliness reason —
# RegistryEntryFile is editor-clean and owns single-entry-file I/O + the builder.
const _RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry_entry_file.gd")


# -- Path helpers (delegate to RegistryPaths — the layout authority) -----------


## Façade pass-through — external callers (unfocused_sleep_controller,
## extension_catalog) bind to RegistryClient.registry_dir().
static func registry_dir() -> String:
	return _RegistryPaths.registry_dir()


static func registry_path() -> String:
	return _RegistryPaths.registry_path()


static func _project_key() -> String:
	return _ProjectKey.current()


static func _entry_dir() -> String:
	return _RegistryPaths.entry_dir()


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


# -- Registry I/O (used by rebuild) -------------------------------------------


static func _write_atomic(data: Dictionary) -> void:
	var path := registry_path()
	var tmp_path := path + ".tmp"
	var bak_path := path + ".bak"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_warning("[MCPRegistry] cannot write %s (err %d)" % [tmp_path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	# Two-phase rename: .tmp → target, with .bak safety net.
	# On Windows DirAccess.rename fails if the target exists, so we
	# rename existing → .bak first, then .tmp → target. If the second
	# rename fails we restore from .bak.
	if FileAccess.file_exists(path):
		# Phase 1: existing → .bak
		if FileAccess.file_exists(bak_path):
			DirAccess.remove_absolute(bak_path)
		var bak_err := DirAccess.rename_absolute(path, bak_path)
		if bak_err != OK:
			push_warning("[MCPRegistry] rename %s -> %s failed (err %d); aborting write" % [path, bak_path, bak_err])
			DirAccess.remove_absolute(tmp_path)
			return
	# Phase 2: .tmp → target
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_warning("[MCPRegistry] rename %s -> %s failed (err %d); restoring from backup" % [tmp_path, path, err])
		# Restore .bak → target if it exists.
		if FileAccess.file_exists(bak_path):
			DirAccess.rename_absolute(bak_path, path)
		DirAccess.remove_absolute(tmp_path)
		return
	# Cleanup .bak on success.
	if FileAccess.file_exists(bak_path):
		DirAccess.remove_absolute(bak_path)


# -- Rebuild projects.json from entry files ------------------------------------

# Fields the runtime child owns. When an editor base entry exists for a _key,
# only these overlay from <hash>.runtime.json — every other field stays the
# editor's. A runtime-only entry (no editor base) is schema-complete on its own.
const _RUNTIME_OWNED_FIELDS := ["runtime_port", "runtime_pid"]


## Scans entries/*.json (+ *.runtime.json) and writes the aggregated
## projects.json. OS.is_process_running() is unreliable on Windows (returns
## false for live sibling editors), so PID-based GC is not used.  Instead, port-
## conflict pruning removes stale editor entries: when two entries claim the
## same port, the one with the older started_at is pruned (its entry
## file is deleted so it doesn't reappear on next rebuild).
## Fresh dead entries are cleaned up by deregister() on normal exit or
## overwritten when the same project reopens (same hash).
## Concurrent rebuilds are idempotent (same files → same output).
## Caller must hold the lock (or accept benign last-writer-wins).
static func _rebuild_projects_json() -> void:
	var dir_path := _entry_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		_write_atomic({"by_path": {}})
		return

	# Pass 1: scan editor (<hash>.json) and runtime (<hash>.runtime.json) files
	# into separate buckets. Each editor item: { data, fpath, port, started_at }.
	var editor_items: Array[Dictionary] = []
	var runtime_entries: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not fname.ends_with(".json") or fname.ends_with(".tmp"):
			fname = dir.get_next()
			continue
		var fpath := dir_path.path_join(fname)
		var f := FileAccess.open(fpath, FileAccess.READ)
		if f == null:
			fname = dir.get_next()
			continue
		var text := f.get_as_text()
		f.close()
		var parsed = JSON.parse_string(text)
		if parsed == null or not parsed is Dictionary or not parsed.has("_key"):
			fname = dir.get_next()
			continue
		var entry: Dictionary = parsed
		if fname.ends_with(".runtime.json"):
			runtime_entries.append(entry)
		else:
			editor_items.append({
				"data": entry,
				"fpath": fpath,
				"port": int(entry.get("port", 0)),
				"started_at": int(entry.get("started_at", 0)),
			})
		fname = dir.get_next()
	dir.list_dir_end()

	# Pass 2: for each port, keep only the newest editor entry (highest
	# started_at). Runtime entries carry port -1, so they never participate.
	var best_by_port: Dictionary = {}  # int → index into editor_items
	var stale_files: Array[String] = []
	var editor_entries: Array[Dictionary] = []
	for i in editor_items.size():
		var port: int = editor_items[i]["port"]
		if port <= 0:
			continue  # No port — keep unconditionally.
		if not best_by_port.has(port):
			best_by_port[port] = i
		else:
			var prev_idx: int = best_by_port[port]
			if editor_items[i]["started_at"] > editor_items[prev_idx]["started_at"]:
				# New entry is newer — prune the old one.
				stale_files.append(editor_items[prev_idx]["fpath"])
				editor_items[prev_idx]["_pruned"] = true
				best_by_port[port] = i
			else:
				# Old entry is newer — prune this one.
				stale_files.append(editor_items[i]["fpath"])
				editor_items[i]["_pruned"] = true
	for item in editor_items:
		if item.get("_pruned", false):
			continue
		editor_entries.append(item["data"])

	# Pass 3: merge editor base + runtime overlay by _key (pure).
	var by_path := _merge_by_path(editor_entries, runtime_entries)

	# Delete stale entry files so they don't reappear on next rebuild.
	for stale_path in stale_files:
		DirAccess.remove_absolute(stale_path)
	_write_atomic({"by_path": by_path})


## Pure: group editor + runtime entries by _key and produce the by_path map.
## For each _key the row is the editor base (minus _key) with the runtime-owned
## fields overlaid from the matching runtime entry. A runtime entry with no
## editor base contributes its full (schema-complete) shape; an editor entry
## with no runtime overlay keeps its own runtime_port/runtime_pid (null). No
## filesystem access — directly unit-testable.
static func _merge_by_path(editor_entries: Array, runtime_entries: Array) -> Dictionary:
	# Index runtime entries by _key for overlay lookup.
	var runtime_by_key: Dictionary = {}
	for re in runtime_entries:
		var re_dict: Dictionary = re
		runtime_by_key[str(re_dict.get("_key", ""))] = re_dict

	var by_path := {}
	# Editor bases first — overlay runtime-owned fields where a runtime entry exists.
	for ee in editor_entries:
		var ee_dict: Dictionary = ee
		var key := str(ee_dict.get("_key", ""))
		var row: Dictionary = ee_dict.duplicate()
		row.erase("_key")
		if runtime_by_key.has(key):
			var rt: Dictionary = runtime_by_key[key]
			for field in _RUNTIME_OWNED_FIELDS:
				row[field] = rt.get(field, null)
		by_path[key] = row
	# Runtime-only entries (no editor base) — use the full runtime shape.
	for rkey in runtime_by_key:
		if by_path.has(rkey):
			continue
		var rt_only: Dictionary = runtime_by_key[rkey]
		var rt_row: Dictionary = rt_only.duplicate()
		rt_row.erase("_key")
		by_path[rkey] = rt_row
	return by_path


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
