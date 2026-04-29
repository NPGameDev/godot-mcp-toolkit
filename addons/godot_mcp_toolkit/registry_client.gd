@tool
extends RefCounted
## System-wide project registry for multi-project concurrency.
##
## Manages a shared projects.json file at an OS-specific location so
## multiple Godot editors can run the MCP plugin simultaneously, each
## on a distinct port. The TypeScript bridge reads this same file to
## discover which port belongs to which project.
##
## All methods are static — no instance state. Callers preload via
## _hub.gd (MCPRegistryClient) or directly.

const _REGISTRY_FILENAME := "projects.json"
const _LOCK_STALE_SEC := 10
const _MAX_ENTRY_AGE_SEC := 86400  # 24 h
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


# -- Registry I/O --------------------------------------------------------------


static func _read_registry() -> Dictionary:
	var path := registry_path()
	if not FileAccess.file_exists(path):
		return {"by_path": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[MCPRegistry] cannot open %s (err %d); using empty registry" % [path, FileAccess.get_open_error()])
		return {"by_path": {}}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_warning("[MCPRegistry] corrupt registry at %s; resetting" % path)
		return {"by_path": {}}
	if not parsed.has("by_path") or not parsed["by_path"] is Dictionary:
		return {"by_path": {}}
	return parsed


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
	# rename fails we restore from .bak. This closes the "file doesn't
	# exist" window that the old remove-then-rename pattern had.
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


# -- Garbage collection --------------------------------------------------------


static func _gc(data: Dictionary) -> Dictionary:
	var by_path: Dictionary = data.get("by_path", {})
	var now := int(Time.get_unix_time_from_system())
	var to_erase: Array[String] = []
	for key in by_path:
		var entry: Dictionary = by_path[key]
		var pid := int(entry.get("pid", 0))
		var started_at := int(entry.get("started_at", 0))
		# Remove entries with dead editor PIDs or older than 24 h.
		if pid > 0 and not OS.is_process_running(pid):
			to_erase.append(str(key))
			continue
		if started_at > 0 and (now - started_at) > _MAX_ENTRY_AGE_SEC:
			to_erase.append(str(key))
			continue
		# Clear stale runtime fields if the runtime process died.
		var runtime_pid = entry.get("runtime_pid", null)
		if runtime_pid != null and int(runtime_pid) > 0:
			if not OS.is_process_running(int(runtime_pid)):
				entry["runtime_port"] = null
				entry["runtime_pid"] = null
	for key in to_erase:
		by_path.erase(key)
	data["by_path"] = by_path
	return data


# -- Public API ----------------------------------------------------------------


static func register(port: int, token_path: String) -> void:
	var key := _project_key()
	var my_pid := OS.get_process_id()
	for retry in 3:
		_acquire_lock()
		var data := _read_registry()
		data = _gc(data)
		var by_path: Dictionary = data["by_path"]
		# Double-open detection: warn if same path already registered with a live PID.
		if by_path.has(key):
			var existing: Dictionary = by_path[key]
			var existing_pid := int(existing.get("pid", 0))
			if existing_pid > 0 and existing_pid != my_pid and OS.is_process_running(existing_pid):
				push_warning("[MCPRegistry] already registered from PID %d; overwriting with PID %d" % [existing_pid, my_pid])
		by_path[key] = {
			"port": port,
			"token_path": token_path,
			"pid": my_pid,
			"started_at": int(Time.get_unix_time_from_system()),
			"runtime_port": null,
			"runtime_pid": null,
		}
		data["by_path"] = by_path
		_write_atomic(data)
		_release_lock()
		# Verify own entry survived — guards against concurrent overwrite
		# when two editors start simultaneously and the lock doesn't provide
		# true mutual exclusion (Godot FileAccess has no O_CREAT|O_EXCL).
		OS.delay_msec(50)
		var verify := _read_registry()
		var v_entry = verify.get("by_path", {}).get(key, null)
		if v_entry != null and int(v_entry.get("pid", 0)) == my_pid:
			print("[MCPRegistry] registered %s on port %d" % [key, port])
			return
		push_warning("[MCPRegistry] entry evicted after write (attempt %d/3); retrying with backoff" % [retry + 1])
		# Random backoff to desynchronise competing editors.
		OS.delay_msec(randi_range(100, 500))
	push_error("[MCPRegistry] FAILED to persist registry entry for %s after 3 attempts — runtime tools may not work in parallel sessions" % key)


static func deregister() -> void:
	_acquire_lock()
	var data := _read_registry()
	var key := _project_key()
	var by_path: Dictionary = data["by_path"]
	if by_path.has(key):
		by_path.erase(key)
		data["by_path"] = by_path
		_write_atomic(data)
		print("[MCPRegistry] deregistered %s" % key)
	_release_lock()


static func set_runtime(runtime_port: int) -> void:
	_acquire_lock()
	var data := _read_registry()
	var key := _project_key()
	var by_path: Dictionary = data["by_path"]
	if by_path.has(key):
		var entry: Dictionary = by_path[key]
		entry["runtime_port"] = runtime_port
		entry["runtime_pid"] = OS.get_process_id()
		by_path[key] = entry
		data["by_path"] = by_path
		_write_atomic(data)
		print("[MCPRegistry] runtime port %d registered for %s" % [runtime_port, key])
	else:
		# Self-heal: entry was lost (concurrent register() overwrote it).
		# Create a minimal entry so the bridge can discover the runtime.
		# pid=0 survives _gc() (PID check requires pid > 0). The bridge
		# already has its editor connection; it only needs runtime_port.
		data = _gc(data)
		by_path[key] = {
			"port": -1,
			"token_path": "",
			"pid": 0,
			"started_at": int(Time.get_unix_time_from_system()),
			"runtime_port": runtime_port,
			"runtime_pid": OS.get_process_id(),
		}
		data["by_path"] = by_path
		_write_atomic(data)
		push_warning("[MCPRegistry] set_runtime: entry missing for %s — created self-heal entry with runtime_port %d" % [key, runtime_port])
	_release_lock()


static func clear_runtime() -> void:
	_acquire_lock()
	var data := _read_registry()
	var key := _project_key()
	var by_path: Dictionary = data["by_path"]
	if by_path.has(key):
		var entry: Dictionary = by_path[key]
		if entry.get("runtime_port", null) != null:
			entry["runtime_port"] = null
			entry["runtime_pid"] = null
			by_path[key] = entry
			data["by_path"] = by_path
			_write_atomic(data)
	_release_lock()


## Read-only lookup: returns the runtime_port for this project, or -1 if
## no runtime is registered. Does NOT acquire a lock (read-only).
static func get_runtime_port() -> int:
	var data := _read_registry()
	var key := _project_key()
	var by_path: Dictionary = data.get("by_path", {})
	if not by_path.has(key):
		return -1
	var entry: Dictionary = by_path[key]
	var rp = entry.get("runtime_port", null)
	if rp == null:
		return -1
	return int(rp)
