@tool
extends RefCounted
## System-wide project registry for multi-project concurrency.
##
## Each Godot editor writes its own entry file under entries/<hash>.json.
## _rebuild_projects_json() aggregates all entry files into projects.json
## so the TypeScript bridge can discover all active editors.
##
## Race-free: concurrent editors write independent files — no shared
## read-modify-write. Concurrent rebuilds are idempotent (same entry
## files → same output).
##
## All methods are static — no instance state. Callers preload via
## _hub.gd (RegistryClient) or directly.

const _VersionUtils := preload("res://addons/godot_mcp_toolkit/mcp_version_utils.gd")

const _REGISTRY_FILENAME := "projects.json"
const _ENTRIES_DIR := "entries"
const _LOCK_STALE_SEC := 10
const _LOCK_BASE_RETRY_MS := 50
const _LOCK_MAX_RETRY_MS := 1000
const _LOCK_RETRIES := 10


# -- Path helpers --------------------------------------------------------------


static func registry_dir() -> String:
	var dir: String
	match OS.get_name():
		"Windows":
			var appdata := OS.get_environment("APPDATA")
			if appdata.is_empty():
				appdata = OS.get_environment("USERPROFILE").path_join("AppData/Roaming")
			dir = appdata.path_join("godot-mcp-toolkit")
		"macOS":
			dir = OS.get_environment("HOME").path_join(
				"Library/Application Support/godot-mcp-toolkit")
		_:  # Linux / BSD
			var data_home := OS.get_environment("XDG_DATA_HOME")
			if data_home.is_empty():
				data_home = OS.get_environment("HOME").path_join(".local/share")
			dir = data_home.path_join("godot-mcp-toolkit")
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	return dir


static func registry_path() -> String:
	return registry_dir().path_join(_REGISTRY_FILENAME)


static func _normalize_path(p: String) -> String:
	var result := p.replace("\\", "/").rstrip("/")
	# Windows and macOS default filesystems are case-insensitive; lowercase
	# avoids mismatches between Godot's globalize_path and Node.js
	# process.cwd() when the TS bridge reads the same registry file.
	if OS.get_name() in ["Windows", "macOS"]:
		result = result.to_lower()
	return result


static func _project_key() -> String:
	return _normalize_path(ProjectSettings.globalize_path("res://"))


static func _entry_dir() -> String:
	var d := registry_dir().path_join(_ENTRIES_DIR)
	if not DirAccess.dir_exists_absolute(d):
		DirAccess.make_dir_recursive_absolute(d)
	return d


static func _entry_hash() -> String:
	return _project_key().sha256_text().substr(0, 12)


static func _entry_file_path() -> String:
	return _entry_dir().path_join(_entry_hash() + ".json")


# -- Lock file -----------------------------------------------------------------


static func _lock_path() -> String:
	return registry_path() + ".lock"


## Returns true if the lock was acquired. On stale-lock detection the
## stale file is overwritten. Exponential backoff: 50, 100, 200, ... ms
## capped at 1000 ms per retry. PID-aware stale detection recovers
## locks from dead processes immediately.
static func _acquire_lock() -> bool:
	var lp := _lock_path()
	var delay_ms := _LOCK_BASE_RETRY_MS
	for attempt in _LOCK_RETRIES:
		if FileAccess.file_exists(lp):
			var f := FileAccess.open(lp, FileAccess.READ)
			if f != null:
				var content := f.get_as_text().strip_edges()
				f.close()
				var parts := content.split(":")
				var lock_pid := int(parts[0]) if parts.size() >= 2 else 0
				var lock_ts := int(parts[-1])
				# PID check: if the locker is dead, treat as stale immediately.
				var pid_dead := lock_pid > 0 and not OS.is_process_running(lock_pid)
				if not pid_dead:
					var age := int(Time.get_unix_time_from_system()) - lock_ts
					if age < _LOCK_STALE_SEC:
						if attempt > 0:
							push_warning("[MCPRegistry] lock contention (attempt %d/%d, held by PID %d)" % [attempt + 1, _LOCK_RETRIES, lock_pid])
						OS.delay_msec(delay_ms)
						delay_ms = mini(delay_ms * 2, _LOCK_MAX_RETRY_MS)
						continue
				# Stale lock (age or dead PID) — fall through to overwrite.
		var f := FileAccess.open(lp, FileAccess.WRITE)
		if f == null:
			OS.delay_msec(delay_ms)
			delay_ms = mini(delay_ms * 2, _LOCK_MAX_RETRY_MS)
			continue
		f.store_string("%d:%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system())])
		f.close()
		return true
	push_warning("[MCPRegistry] failed to acquire lock after %d retries; proceeding anyway" % _LOCK_RETRIES)
	# Force-write the lock as a last resort so the caller can proceed.
	var f := FileAccess.open(lp, FileAccess.WRITE)
	if f != null:
		f.store_string("%d:%d" % [OS.get_process_id(), int(Time.get_unix_time_from_system())])
		f.close()
	return true


static func _release_lock() -> void:
	var lp := _lock_path()
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(lp)


## Public lock wrappers for callers that need to serialise a machine-wide
## read-modify-write on a sibling file in registry_dir() across concurrent
## editor instances (e.g. the unfocused-sleep backup — see mcp_server.gd /
## unfocused_backup.gd). Same lock as the registry's own writes, so backup and
## registry operations are mutually exclusive (both are rare and fast).
static func acquire_lock() -> bool:
	return _acquire_lock()


static func release_lock() -> void:
	_release_lock()


# -- Entry-file I/O -----------------------------------------------------------


static func _write_entry(entry: Dictionary) -> void:
	var path := _entry_file_path()
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("[MCPRegistry] cannot write entry %s (err %d)" % [tmp, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(entry, "\t"))
	f.close()
	# Atomic rename: remove target first (Windows rename fails if exists).
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("[MCPRegistry] rename %s -> %s failed (err %d)" % [tmp, path, err])
		DirAccess.remove_absolute(tmp)


static func _read_entry() -> Dictionary:
	var path := _entry_file_path()
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		return {}
	return parsed


static func _delete_entry() -> void:
	var path := _entry_file_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


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


## Scans entries/*.json and writes the aggregated projects.json.
## OS.is_process_running() is unreliable on Windows (returns false for
## live sibling editors), so PID-based GC is not used.  Instead, port-
## conflict pruning removes stale entries: when two entries claim the
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

	# Pass 1: scan all entry files.
	# Each item: { key, entry_dict, fpath, port, started_at }
	var all_entries: Array[Dictionary] = []
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
		all_entries.append({
			"key": parsed["_key"],
			"data": parsed,
			"fpath": fpath,
			"port": int(parsed.get("port", 0)),
			"started_at": int(parsed.get("started_at", 0)),
		})
		fname = dir.get_next()
	dir.list_dir_end()

	# Pass 2: for each port, keep only the newest entry (highest started_at).
	# port → index of the best (newest) entry in all_entries.
	var best_by_port: Dictionary = {}  # int → int
	var stale_files: Array[String] = []
	for i in all_entries.size():
		var port: int = all_entries[i]["port"]
		if port <= 0:
			continue  # No port — keep unconditionally.
		if not best_by_port.has(port):
			best_by_port[port] = i
		else:
			var prev_idx: int = best_by_port[port]
			if all_entries[i]["started_at"] > all_entries[prev_idx]["started_at"]:
				# New entry is newer — prune the old one.
				stale_files.append(all_entries[prev_idx]["fpath"])
				all_entries[prev_idx]["_pruned"] = true
				best_by_port[port] = i
			else:
				# Old entry is newer — prune this one.
				stale_files.append(all_entries[i]["fpath"])
				all_entries[i]["_pruned"] = true

	# Pass 3: build by_path from surviving entries.
	var by_path := {}
	for item in all_entries:
		if item.get("_pruned", false):
			continue
		var key: String = item["key"]
		var entry: Dictionary = (item["data"] as Dictionary).duplicate()
		entry.erase("_key")
		by_path[key] = entry

	# Delete stale entry files so they don't reappear on next rebuild.
	for stale_path in stale_files:
		DirAccess.remove_absolute(stale_path)
	_write_atomic({"by_path": by_path})


# -- Public API ----------------------------------------------------------------


## Build a registry entry dict from the given facts. Pure — no FS access, no
## EditorInterface: the editor side resolves the LSP endpoint
## (MCPServer.resolve_lsp_endpoint) and passes lsp_host/lsp_port in, so this file
## stays editor-clean and the Mode-B runtime autoload can safely preload it
## (naming an editor-only class here would parse-fail the autoload in exports —
## godot#91713). lsp_port/runtime_* are untyped: int when known, null otherwise.
static func _build_entry(key: String, port: int, token_path: String,
		lsp_host: String, lsp_port, runtime_port, runtime_pid) -> Dictionary:
	return {
		"_key": key,
		"port": port,
		"token_path": token_path,
		"pid": OS.get_process_id(),
		"started_at": int(Time.get_unix_time_from_system()),
		"godot_version": _VersionUtils.get_engine_version_pair(),
		"runtime_port": runtime_port,
		"runtime_pid": runtime_pid,
		"lsp_host": lsp_host,
		"lsp_port": lsp_port,
	}


static func register(port: int, token_path: String, lsp_host: String, lsp_port: int) -> void:
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
	_acquire_lock()
	_rebuild_projects_json()
	_release_lock()
	print("[MCPRegistry] registered %s on port %d" % [key, port])


static func deregister() -> void:
	var key := _project_key()
	_delete_entry()
	_acquire_lock()
	_rebuild_projects_json()
	_release_lock()
	print("[MCPRegistry] deregistered %s" % key)


static func set_runtime(runtime_port: int) -> void:
	var key := _project_key()
	var my_pid := OS.get_process_id()
	var entry := _read_entry()
	if entry.is_empty():
		# Self-heal: entry file was lost — create a minimal one. No editor here to
		# resolve the LSP endpoint (set_runtime runs from the runtime autoload), so
		# publish lsp_port: null — the server reads a null lsp_port as a miss.
		entry = {
			"_key": key,
			"port": -1,
			"token_path": "",
			"pid": 0,
			"started_at": int(Time.get_unix_time_from_system()),
			"runtime_port": runtime_port,
			"runtime_pid": my_pid,
			"lsp_host": "127.0.0.1",
			"lsp_port": null,
		}
		push_warning("[MCPRegistry] set_runtime: entry file missing for %s — created self-heal entry" % key)
	else:
		entry["runtime_port"] = runtime_port
		entry["runtime_pid"] = my_pid
	_write_entry(entry)
	_acquire_lock()
	_rebuild_projects_json()
	_release_lock()
	print("[MCPRegistry] runtime port %d registered for %s" % [runtime_port, key])


static func clear_runtime() -> void:
	var entry := _read_entry()
	if entry.is_empty():
		return
	if entry.get("runtime_port", null) == null:
		return  # Already cleared
	entry["runtime_port"] = null
	entry["runtime_pid"] = null
	_write_entry(entry)
	_acquire_lock()
	_rebuild_projects_json()
	_release_lock()


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
		_acquire_lock()
		_rebuild_projects_json()
		_release_lock()
		return
	# Entry file missing or wrong PID — re-create.
	var runtime_port = null
	var runtime_pid = null
	if not entry.is_empty():
		runtime_port = entry.get("runtime_port", null)
		runtime_pid = entry.get("runtime_pid", null)
	push_warning("[MCPRegistry] entry file missing during deferred re-verify; re-creating for %s" % key)
	var new_entry := _build_entry(key, port, token_path, lsp_host, lsp_port, runtime_port, runtime_pid)
	_write_entry(new_entry)
	_acquire_lock()
	_rebuild_projects_json()
	_release_lock()
	print("[MCPRegistry] re-registered %s on port %d (deferred)" % [key, port])


## Read-only: returns the runtime_port for this project, or -1.
static func get_runtime_port() -> int:
	var entry := _read_entry()
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


## Best-effort count of OTHER live editors publishing the same LSP port as us — a
## UI-only conflict hint (the server's PID-liveness check is authoritative). Uses
## OS.is_process_running, which false-negatives for live siblings on Windows, so
## this can undercount; it never false-positives. Pure — no EditorInterface.
static func lsp_conflict_peers() -> int:
	var mine := _read_entry()
	var my_port = mine.get("lsp_port", null)
	if my_port == null:
		return 0
	var path := registry_path()
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null or not parsed is Dictionary:
		return 0
	var my_key := _project_key()
	var count := 0
	for key in parsed.get("by_path", {}):
		if key == my_key:
			continue
		var entry = parsed["by_path"][key]
		if not entry is Dictionary or entry.get("lsp_port", null) != my_port:
			continue
		var pid := int(entry.get("pid", 0))
		if pid > 0 and OS.is_process_running(pid):
			count += 1
	return count
