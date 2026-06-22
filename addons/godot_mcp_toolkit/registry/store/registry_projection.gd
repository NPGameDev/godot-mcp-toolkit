@tool
extends RefCounted
## Builds the projection / read-model projects.json from the per-instance entry
## files. DDD: this is a PROJECTION, not a transactional aggregate root — the
## per-instance entry files (<hash>.json, <hash>.runtime.json) are the write-side
## aggregates (one writer each); projects.json is the derived, fanned-in read
## model the TypeScript bridge reads. It is owned by no one and rebuilt
## idempotently (same entry files → same output).
##
## The rebuild scans all entry files, port-conflict-prunes stale editor entries,
## overlays the runtime entries onto the editor base by _key, and atomically
## writes projects.json. The caller holds the lock (or accepts benign
## last-writer-wins) — see RegistryClient's lifecycle methods.
##
## All methods are static — no instance state. Editor-clean: this file is in the
## runtime autoload's preload closure (via registry_client.gd), so it names no
## editor-only class (godot#91713).

# Direct preload (NOT via core/modules.gd): this file is in the runtime autoload's
# preload closure (registry_client.gd → mcp_runtime_server.gd), so it must stay
# editor-clean — core/modules.gd names EditorInterface and would taint the autoload in
# exports (godot#91713). RegistryPaths is editor-clean and owns the on-disk layout.
const _RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")


# -- Registry I/O (used by rebuild) -------------------------------------------


static func write_atomic(data: Dictionary) -> void:
	var path := _RegistryPaths.registry_path()
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
static func rebuild() -> void:
	var dir_path := _RegistryPaths.entry_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		write_atomic({"by_path": {}})
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
	var by_path := merge_by_path(editor_entries, runtime_entries)

	# Delete stale entry files so they don't reappear on next rebuild.
	for stale_path in stale_files:
		DirAccess.remove_absolute(stale_path)
	write_atomic({"by_path": by_path})


## Pure: group editor + runtime entries by _key and produce the by_path map.
## For each _key the row is the editor base (minus _key) with the runtime-owned
## fields overlaid from the matching runtime entry. A runtime entry with no
## editor base contributes its full (schema-complete) shape; an editor entry
## with no runtime overlay keeps its own runtime_port/runtime_pid (null). No
## filesystem access — directly unit-testable.
static func merge_by_path(editor_entries: Array, runtime_entries: Array) -> Dictionary:
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
