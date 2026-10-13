@tool
extends RefCounted
## Project/instance registry store unit tests: ProjectKey identity, RegistryPaths
## layout, RegistryEntryFile build + write/read/delete, RegistryProjection merge,
## the FileLock acquire/release cycle and RegistryClient's double-open check.

const FileLock := preload("res://addons/godot_mcp_toolkit/registry/store/file_lock.gd")
const ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")
const RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")
const RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry/store/registry_entry_file.gd")
const RegistryProjection := preload("res://addons/godot_mcp_toolkit/registry/store/registry_projection.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")

# A PID for a lock or an entry that another editor wrote.
const _OTHER_PID := 4242


static func run(testing) -> void:
	_test_project_key(testing)
	_test_registry_paths(testing)
	_test_registry_entry(testing)
	_test_registry_entry_file_io(testing)
	_test_registry_merge(testing)
	_test_file_lock(testing)
	_test_double_open_check(testing)


# True on case-insensitive default filesystems (Windows/macOS), where
# ProjectKey.canonical lowercases — mirrors the recipe's own platform branch so
# the canonicalization assertions are correct on every host.
static func _case_folds() -> bool:
	return OS.get_name() in ["Windows", "macOS"]


# --- ProjectKey identity (005-D shared-kernel keystone) -------------------
# The single canonicalization SSOT: normalize a project root and derive its
# 12-char hash. Pins the recipe (slash + trailing-slash + case-fold) and the
# hash, plus the Shared-Kernel invariant that ProjectPaths (the user:// dir
# hash) and RegistryClient (the entry-file hash) can never drift apart.
static func _test_project_key(testing) -> void:
	testing.begin("ProjectKey identity")

	# 1. Normalization: backslash → slash, trailing slash(es) stripped.
	testing.eq(ProjectKey.canonical("C:\\a\\b"), "c:/a/b" if _case_folds() else "C:/a/b",
			"canonical: backslash → slash")
	testing.eq(ProjectKey.canonical("/a/b/"), "/a/b", "canonical: trailing slash stripped")
	testing.eq(ProjectKey.canonical("/a/b///"), "/a/b", "canonical: repeated trailing slashes stripped")
	testing.eq(ProjectKey.canonical(""), "", "canonical: empty stays empty")

	# 2. Case-fold is filesystem-conditional (Windows/macOS lowercase, else verbatim).
	if _case_folds():
		testing.eq(ProjectKey.canonical("/A/B"), "/a/b", "canonical: lowercased on case-insensitive FS")
	else:
		testing.eq(ProjectKey.canonical("/A/B"), "/A/B", "canonical: case preserved on case-sensitive FS")

	# 3. hash_of: 12 hex chars, deterministic, and hashes its argument VERBATIM
	#    (no re-canonicalization) — two different strings give two different hashes.
	var hash := ProjectKey.hash_of("/some/canonical/key")
	testing.eq(hash.length(), 12, "hash_of: 12 chars")
	testing.eq(ProjectKey.hash_of("/some/canonical/key"), hash, "hash_of: deterministic")
	testing.ok(ProjectKey.hash_of("/some/canonical/key") != ProjectKey.hash_of("/other/key"),
			"hash_of: distinct inputs → distinct hashes")
	testing.ok(ProjectKey.hash_of("/A/B") != ProjectKey.hash_of("/a/b"),
			"hash_of: hashes verbatim (does not re-canonicalize)")

	# 4. current_hash() == hash_of(current()) by construction.
	testing.eq(ProjectKey.current_hash(), ProjectKey.hash_of(ProjectKey.current()),
			"current_hash == hash_of(current)")

	# 5. Shared-Kernel pin (005-D): ONE canonicalization, two consumers. The
	#    user:// instance-dir hash (ProjectPaths) and the registry entry-file hash
	#    (ProjectKey) MUST match, or a single instance would split into two
	#    identities. This single assertion guards the de-dup against future drift.
	testing.eq(ProjectPaths.project_hash(), ProjectKey.current_hash(),
			"005-D: ProjectPaths.project_hash() == ProjectKey.current_hash()")

	print("")


# --- RegistryPaths layout --------------------------------------------------
# The on-disk layout authority: the machine-wide registry dir + every canonical
# path within it. Pins the path SHAPE (filename suffixes + the lock-path
# derivation) without asserting filesystem state, which is environmental. The
# per-instance entry filenames carry ProjectKey.current_hash() — one
# canonicalization, shared with the user:// instance dir.
static func _test_registry_paths(testing) -> void:
	testing.begin("RegistryPaths layout")

	# 1. projects.json is the aggregate file under the registry dir.
	testing.ok(RegistryPaths.registry_path().ends_with("projects.json"),
			"registry_path ends with projects.json")
	testing.eq(RegistryPaths.registry_path(),
			RegistryPaths.registry_dir().path_join("projects.json"),
			"registry_path == registry_dir/projects.json")

	# 2. Entry files live in entries/ and are keyed by the project hash.
	var hash := ProjectKey.current_hash()
	testing.ok(RegistryPaths.entry_dir().ends_with("entries"),
			"entry_dir ends with entries")
	testing.eq(RegistryPaths.entry_file_path(),
			RegistryPaths.entry_dir().path_join(hash + ".json"),
			"entry_file_path == entry_dir/<hash>.json")
	testing.eq(RegistryPaths.runtime_entry_file_path(),
			RegistryPaths.entry_dir().path_join(hash + ".runtime.json"),
			"runtime_entry_file_path == entry_dir/<hash>.runtime.json")

	# 3. The two entry files are distinct (editor base vs runtime overlay).
	testing.ok(RegistryPaths.entry_file_path() != RegistryPaths.runtime_entry_file_path(),
			"editor entry path != runtime entry path")

	# 4. The lock file is the registry path + ".lock".
	testing.eq(RegistryPaths.lock_path(), RegistryPaths.registry_path() + ".lock",
			"lock_path == registry_path + .lock")

	# 5. The façade still routes through here (callers bind to RegistryClient).
	testing.eq(RegistryClient.registry_dir(), RegistryPaths.registry_dir(),
			"RegistryClient.registry_dir delegates to RegistryPaths")

	print("")


# --- RegistryEntryFile.build_entry (pure entry-dict builder) ---------------
# RegistryEntryFile.build_entry is pure (no FS, no EditorInterface): the editor
# resolves the LSP endpoint (LspPublisher.resolve_lsp_endpoint, also reachable via the
# thin static MCPServer.resolve_lsp_endpoint delegate — editor-coupled, interactive-
# verified) and passes it in, so the entry written to projects.json carries
# lsp_host/lsp_port for the server's per-project LSP discovery.
static func _test_registry_entry(testing) -> void:
	testing.begin("RegistryEntryFile build_entry")

	# 1. Entry carries the LSP endpoint the editor passed in.
	var entry := RegistryEntryFile.build_entry("res://proj", 6550, "tok", "127.0.0.1", 6005, null, null)
	testing.eq(entry.get("lsp_host", ""), "127.0.0.1", "entry carries lsp_host")
	testing.eq(entry.get("lsp_port", -1), 6005, "entry carries lsp_port")

	# 2. WS port stays distinct from the LSP port; core keys present.
	testing.eq(entry.get("port", -1), 6550, "entry carries ws port (distinct from lsp_port)")
	testing.eq(entry.get("token_path", ""), "tok", "entry carries token_path")
	testing.ok(entry.has("_key") and entry.has("pid") and entry.has("started_at"),
			"entry carries core keys (_key/pid/started_at)")
	testing.ok(entry.get("runtime_port") == null, "no runtime → runtime_port null")

	# 3. A custom (non-default) LSP port + an active runtime flow through unchanged.
	var custom_entry := RegistryEntryFile.build_entry("res://proj", 6551, "tok", "127.0.0.1", 6010, 6570, 4242)
	testing.eq(custom_entry.get("lsp_port", -1), 6010, "custom lsp_port flows through")
	testing.eq(custom_entry.get("runtime_port", -1), 6570, "runtime_port preserved when set")

	print("")


# --- RegistryEntryFile write/read/delete round-trip -----------------------
# The path-keyed atomic I/O leaf: a write then read returns the same dict; a
# delete removes the file so a subsequent read is empty; reading a path that was
# never written is empty too. Uses a user:// temp path and cleans up after.
static func _test_registry_entry_file_io(testing) -> void:
	testing.begin("RegistryEntryFile write/read/delete")

	var tmp := "user://_test_registry_entry_file_%d.json" % OS.get_process_id()
	# Start clean in case a prior aborted run left the file behind.
	RegistryEntryFile.delete(tmp)

	# 1. Reading a path that was never written → empty dict.
	testing.eq(RegistryEntryFile.read(tmp), {}, "read(nonexistent) → {}")

	# 2. write → read round-trips every field. JSON parses numbers as float, so
	#    the numeric field reads back as a float — assert it via int() (exactly
	#    how production reads it back, e.g. get_runtime_port), not a whole-dict
	#    compare that would spuriously fail on int-vs-float.
	var entry := {
		"_key": "res://proj",
		"port": 6550,
		"token_path": "tok",
		"runtime_port": null,
	}
	RegistryEntryFile.write(tmp, entry)
	var got: Dictionary = RegistryEntryFile.read(tmp)
	testing.eq(got.size(), entry.size(), "write then read → same field count")
	testing.eq(got.get("_key", ""), "res://proj", "round-trip: _key preserved")
	testing.eq(int(got.get("port", -1)), 6550, "round-trip: port (JSON floats ints → int())")
	testing.eq(got.get("token_path", ""), "tok", "round-trip: token_path preserved")
	testing.ok(got.get("runtime_port", 0) == null, "round-trip: runtime_port null preserved")

	# 3. delete → the file is gone, so read returns empty again.
	RegistryEntryFile.delete(tmp)
	testing.eq(RegistryEntryFile.read(tmp), {}, "delete then read → {}")

	print("")


# --- RegistryClient entry merge (runtime overlay onto editor base) --------
# The editor process owns entries/<hash>.json; its runtime child owns
# entries/<hash>.runtime.json (one writer per file — no shared RMW). The rebuild
# merges them by _key: runtime_port/runtime_pid overlay the editor base. This
# pins the pure merge so the aggregate projects.json shape stays identical to the
# pre-split single-file layout the server reads.
static func _test_registry_merge(testing) -> void:
	testing.begin("RegistryClient entry merge")

	var editor_entry := RegistryEntryFile.build_entry(
		"res://proj", 6550, "tok", "127.0.0.1", 6005, null, null)

	# 1. Runtime overlay onto an editor base — runtime fields win, the rest is
	#    the editor's, and the row carries exactly the editor key set (no _key).
	var runtime_entry := {
		"_key": "res://proj",
		"port": -1,
		"token_path": "",
		"pid": 4242,
		"started_at": 999,
		"godot_version": "4.5",
		"runtime_port": 6570,
		"runtime_pid": 4242,
		"lsp_host": "127.0.0.1",
		"lsp_port": null,
	}
	var merged: Dictionary = RegistryProjection.merge_by_path([editor_entry], [runtime_entry])
	var row: Dictionary = merged.get("res://proj", {})
	testing.eq(row.get("runtime_port", -1), 6570, "overlay: runtime_port from runtime file")
	testing.eq(row.get("runtime_pid", -1), 4242, "overlay: runtime_pid from runtime file")
	# Editor-owned fields are NOT clobbered by the runtime file's placeholders.
	testing.eq(row.get("port", -99), 6550, "overlay: editor port preserved (not -1)")
	testing.eq(row.get("token_path", "x"), "tok", "overlay: editor token_path preserved (not empty)")
	testing.eq(row.get("lsp_port", -1), 6005, "overlay: editor lsp_port preserved (not null)")
	testing.ok(not row.has("_key"), "overlay: _key erased from row")

	# 2. Runtime-only entry (no editor base) — full runtime shape stands in, and
	#    it is schema-complete: port -1, token_path "", and godot_version present.
	var only: Dictionary = RegistryProjection.merge_by_path([], [runtime_entry])
	var orow: Dictionary = only.get("res://proj", {})
	testing.eq(orow.get("runtime_port", -1), 6570, "runtime-only: runtime_port present")
	testing.eq(orow.get("port", -99), -1, "runtime-only: port -1")
	testing.eq(orow.get("token_path", "x"), "", "runtime-only: token_path empty")
	testing.ok(orow.has("godot_version"), "runtime-only: godot_version present (schema-complete)")
	testing.eq(orow.get("lsp_port", -99), null, "runtime-only: lsp_port null")
	testing.ok(not orow.has("_key"), "runtime-only: _key erased")

	# 3. Editor-only entry (no runtime overlay) — runtime fields stay the editor
	#    base's null; the row is the editor entry verbatim minus _key.
	var eonly: Dictionary = RegistryProjection.merge_by_path([editor_entry], [])
	var erow: Dictionary = eonly.get("res://proj", {})
	testing.eq(erow.get("runtime_port", -99), null, "editor-only: runtime_port null")
	testing.eq(erow.get("runtime_pid", -99), null, "editor-only: runtime_pid null")
	testing.eq(erow.get("port", -99), 6550, "editor-only: editor port preserved")
	testing.ok(not erow.has("_key"), "editor-only: _key erased")

	# 4. clear_runtime semantics: dropping the runtime file removes the overlay —
	#    re-merging without it returns the editor base (runtime fields back to null).
	var cleared: Dictionary = RegistryProjection.merge_by_path([editor_entry], [])
	testing.eq(cleared.get("res://proj", {}).get("runtime_port", -99), null,
		"clear: overlay gone → runtime_port back to null")

	print("")


# --- FileLock acquire/release ---------------------------------------------
# The lock excludes by age alone. The fresh-lock case names another PID, one
# this process did not start: OS.is_process_running() reads such a PID as not
# running on Windows and Linux, and on macOS unless it is a running GUI app, so
# a liveness check through it takes the lock at once. Not this process's own PID: Windows lists the engine's own PID among
# the processes it started, so the call reports that one as running.
static func _test_file_lock(testing) -> void:
	testing.begin("FileLock acquire/release")

	var my_pid := OS.get_process_id()
	var lock_path := "user://_test_file_lock_%d.lock" % my_pid
	# Start clean in case a prior aborted run left the file behind.
	FileLock.release(lock_path)

	# 1. A fresh lock is held until its holder releases it: a worker thread
	#    releases it after 300 ms, and acquire() waits for that.
	var holder_pid := _OTHER_PID if _OTHER_PID != my_pid else _OTHER_PID + 1
	_write_lock(lock_path, holder_pid, int(Time.get_unix_time_from_system()))
	var releaser := _DelayedRelease.new(lock_path, 300)
	var thread := Thread.new()
	var started_at := Time.get_ticks_msec()
	testing.eq(thread.start(releaser.run), OK, "fresh lock: the releasing thread starts")
	var acquired := FileLock.acquire(lock_path)
	var waited_ms := Time.get_ticks_msec() - started_at
	thread.wait_to_finish()
	testing.ok(acquired, "fresh lock: acquire() returns true once released")
	testing.ok(waited_ms >= 250, "fresh lock: acquire() waits for the holder")
	testing.eq(_lock_pid(lock_path), my_pid, "fresh lock: the file names this PID")

	# 2. A lock stamped 11 s ago is stale: taken without waiting out the retries
	#    (6.55 s in all), and rewritten with this PID.
	FileLock.release(lock_path)
	_write_lock(lock_path, _OTHER_PID, int(Time.get_unix_time_from_system()) - 11)
	started_at = Time.get_ticks_msec()
	acquired = FileLock.acquire(lock_path)
	waited_ms = Time.get_ticks_msec() - started_at
	testing.ok(acquired, "stale lock: acquire() returns true")
	testing.ok(waited_ms < 1000, "stale lock: taken in under 1000 ms")
	testing.eq(_lock_pid(lock_path), my_pid, "stale lock: rewritten with this PID")

	# 3. release() removes the lock file.
	FileLock.release(lock_path)
	testing.ok(not FileAccess.file_exists(lock_path), "release(): the lock file is gone")

	print("")


# --- RegistryClient double-open check --------------------------------------
# register() warns of a second editor only when another PID's entry names a port
# other than the one this editor bound; an entry naming this editor's port was
# left by an editor that is gone. Entries carry floats for numbers, as
# RegistryEntryFile.read returns them (JSON numbers parse as float).
static func _test_double_open_check(testing) -> void:
	testing.begin("RegistryClient double-open check")

	var my_pid := 1000
	var my_port := 6550
	testing.ok(not RegistryClient._should_warn_double_open({}, my_pid, my_port),
			"no entry → no warning")
	testing.ok(not RegistryClient._should_warn_double_open(
			{"pid": 1000.0, "port": 6551.0}, my_pid, my_port),
			"this PID's own entry → no warning")
	testing.ok(not RegistryClient._should_warn_double_open(
			{"pid": 4242.0, "port": 6550.0}, my_pid, my_port),
			"another PID's entry on this editor's port → no warning (a leftover)")
	testing.ok(RegistryClient._should_warn_double_open(
			{"pid": 4242.0, "port": 6551.0}, my_pid, my_port),
			"another PID's entry on another port → warning")

	print("")


static func _write_lock(lock_path: String, pid: int, unix_ts: int) -> void:
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	f.store_string("%d:%d" % [pid, unix_ts])
	f.close()


# The PID a lock file names, or 0 when the file is missing.
static func _lock_pid(lock_path: String) -> int:
	return int(FileAccess.get_file_as_string(lock_path).split(":")[0])


# Releases a lock from a worker thread after a delay, standing in for another
# editor that holds the lock for that long.
class _DelayedRelease extends RefCounted:
	const _FileLock := preload("res://addons/godot_mcp_toolkit/registry/store/file_lock.gd")

	var _lock_path: String
	var _delay_ms: int

	func _init(lock_path: String, delay_ms: int) -> void:
		_lock_path = lock_path
		_delay_ms = delay_ms

	func run() -> void:
		OS.delay_msec(_delay_ms)
		_FileLock.release(_lock_path)
