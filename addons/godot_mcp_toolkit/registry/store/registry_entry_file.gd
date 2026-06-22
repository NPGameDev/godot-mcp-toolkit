@tool
extends RefCounted
## Single registry-entry-file I/O for the multi-instance registry.
##
## Reads, writes, and deletes ONE entry file atomically, and builds the entry
## dict written to it. Path-keyed: the caller passes the exact file path
## (RegistryPaths.entry_file_path() / runtime_entry_file_path()) — there are no
## current-instance convenience wrappers, which keeps this a stateless,
## ProjectSettings-free leaf that is trivially unit-testable.
##
## All methods are static — no instance state. Editor-clean: this file is in the
## runtime autoload's preload closure (via registry_client.gd), so it names no
## editor-only class (godot#91713). The editor side resolves the LSP endpoint and
## passes lsp_host/lsp_port into build_entry, so this file never touches
## EditorInterface.

const _VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")


# -- Single-entry-file I/O -----------------------------------------------------


# Each writer owns its own file (editor: <hash>.json, runtime: <hash>.runtime.json),
# so the per-path .tmp names never collide between the two processes.
static func write(path: String, entry: Dictionary) -> void:
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


static func read(path: String) -> Dictionary:
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


static func delete(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


# -- Entry-dict builder --------------------------------------------------------


## Build a registry entry dict from the given facts. Pure — no FS access, no
## EditorInterface: the editor side resolves the LSP endpoint
## (MCPServer.resolve_lsp_endpoint) and passes lsp_host/lsp_port in, so this file
## stays editor-clean and the Mode-B runtime autoload can safely preload it
## (naming an editor-only class here would parse-fail the autoload in exports —
## godot#91713). lsp_port/runtime_* are untyped: int when known, null otherwise.
static func build_entry(key: String, port: int, token_path: String,
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
