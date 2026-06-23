@tool
extends RefCounted
## Project/instance registry store unit tests: ProjectKey identity, RegistryPaths
## layout, RegistryEntryFile build + write/read/delete, RegistryProjection merge.

const ProjectKey := preload("res://addons/godot_mcp_toolkit/paths/project_key.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")
const RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")
const RegistryEntryFile := preload("res://addons/godot_mcp_toolkit/registry/store/registry_entry_file.gd")
const RegistryProjection := preload("res://addons/godot_mcp_toolkit/registry/store/registry_projection.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")


static func run(h) -> void:
	_test_project_key(h)
	_test_registry_paths(h)
	_test_registry_entry(h)
	_test_registry_entry_file_io(h)
	_test_registry_merge(h)


# True on case-insensitive default filesystems (Windows/macOS), where
# ProjectKey.canonical lowercases — mirrors the recipe's own platform branch so
# the canonicalization assertions are correct on every host.
static func _case_folds() -> bool:
	return OS.get_name() in ["Windows", "macOS"]


# --- ProjectKey identity (concern 039 C0, 005-D) --------------------------
# The single canonicalization SSOT: normalize a project root and derive its
# 12-char hash. Pins the recipe (slash + trailing-slash + case-fold) and the
# hash, plus the Shared-Kernel invariant that ProjectPaths (the user:// dir
# hash) and RegistryClient (the entry-file hash) can never drift apart.
static func _test_project_key(h) -> void:
	h.begin("ProjectKey identity")

	# 1. Normalization: backslash → slash, trailing slash(es) stripped.
	h.eq(ProjectKey.canonical("C:\\a\\b"), "c:/a/b" if _case_folds() else "C:/a/b",
			"canonical: backslash → slash")
	h.eq(ProjectKey.canonical("/a/b/"), "/a/b", "canonical: trailing slash stripped")
	h.eq(ProjectKey.canonical("/a/b///"), "/a/b", "canonical: repeated trailing slashes stripped")
	h.eq(ProjectKey.canonical(""), "", "canonical: empty stays empty")

	# 2. Case-fold is filesystem-conditional (Windows/macOS lowercase, else verbatim).
	if _case_folds():
		h.eq(ProjectKey.canonical("/A/B"), "/a/b", "canonical: lowercased on case-insensitive FS")
	else:
		h.eq(ProjectKey.canonical("/A/B"), "/A/B", "canonical: case preserved on case-sensitive FS")

	# 3. hash_of: 12 hex chars, deterministic, and hashes its argument VERBATIM
	#    (no re-canonicalization) — two different strings give two different hashes.
	var hash := ProjectKey.hash_of("/some/canonical/key")
	h.eq(hash.length(), 12, "hash_of: 12 chars")
	h.eq(ProjectKey.hash_of("/some/canonical/key"), hash, "hash_of: deterministic")
	h.ok(ProjectKey.hash_of("/some/canonical/key") != ProjectKey.hash_of("/other/key"),
			"hash_of: distinct inputs → distinct hashes")
	h.ok(ProjectKey.hash_of("/A/B") != ProjectKey.hash_of("/a/b"),
			"hash_of: hashes verbatim (does not re-canonicalize)")

	# 4. current_hash() == hash_of(current()) by construction.
	h.eq(ProjectKey.current_hash(), ProjectKey.hash_of(ProjectKey.current()),
			"current_hash == hash_of(current)")

	# 5. Shared-Kernel pin (005-D): ONE canonicalization, two consumers. The
	#    user:// instance-dir hash (ProjectPaths) and the registry entry-file hash
	#    (ProjectKey) MUST match, or a single instance would split into two
	#    identities. This single assertion guards the de-dup against future drift.
	h.eq(ProjectPaths.project_hash(), ProjectKey.current_hash(),
			"005-D: ProjectPaths.project_hash() == ProjectKey.current_hash()")

	print("")


# --- RegistryPaths layout (concern 039 C1) --------------------------------
# The on-disk layout authority: the machine-wide registry dir + every canonical
# path within it. Pins the path SHAPE (filename suffixes + the lock-path
# derivation) without asserting filesystem state, which is environmental. The
# per-instance entry filenames carry ProjectKey.current_hash() — one
# canonicalization, shared with the user:// instance dir.
static func _test_registry_paths(h) -> void:
	h.begin("RegistryPaths layout")

	# 1. projects.json is the aggregate file under the registry dir.
	h.ok(RegistryPaths.registry_path().ends_with("projects.json"),
			"registry_path ends with projects.json")
	h.eq(RegistryPaths.registry_path(),
			RegistryPaths.registry_dir().path_join("projects.json"),
			"registry_path == registry_dir/projects.json")

	# 2. Entry files live in entries/ and are keyed by the project hash.
	var hash := ProjectKey.current_hash()
	h.ok(RegistryPaths.entry_dir().ends_with("entries"),
			"entry_dir ends with entries")
	h.eq(RegistryPaths.entry_file_path(),
			RegistryPaths.entry_dir().path_join(hash + ".json"),
			"entry_file_path == entry_dir/<hash>.json")
	h.eq(RegistryPaths.runtime_entry_file_path(),
			RegistryPaths.entry_dir().path_join(hash + ".runtime.json"),
			"runtime_entry_file_path == entry_dir/<hash>.runtime.json")

	# 3. The two entry files are distinct (editor base vs runtime overlay).
	h.ok(RegistryPaths.entry_file_path() != RegistryPaths.runtime_entry_file_path(),
			"editor entry path != runtime entry path")

	# 4. The lock file is the registry path + ".lock".
	h.eq(RegistryPaths.lock_path(), RegistryPaths.registry_path() + ".lock",
			"lock_path == registry_path + .lock")

	# 5. The façade still routes through here (callers bind to RegistryClient).
	h.eq(RegistryClient.registry_dir(), RegistryPaths.registry_dir(),
			"RegistryClient.registry_dir delegates to RegistryPaths")

	print("")


# --- RegistryEntryFile build_entry (concern 039 C2) ------------------------
# RegistryEntryFile.build_entry is pure (no FS, no EditorInterface): the editor
# resolves the LSP endpoint (LspPublisher.resolve_lsp_endpoint, also reachable via the
# thin static MCPServer.resolve_lsp_endpoint delegate — editor-coupled, interactive-
# verified) and passes it in, so the entry written to projects.json carries
# lsp_host/lsp_port for the server's per-project LSP discovery.
static func _test_registry_entry(h) -> void:
	h.begin("RegistryEntryFile build_entry")

	# 1. Entry carries the LSP endpoint the editor passed in.
	var e := RegistryEntryFile.build_entry("res://proj", 6550, "tok", "127.0.0.1", 6005, null, null)
	h.eq(e.get("lsp_host", ""), "127.0.0.1", "entry carries lsp_host")
	h.eq(e.get("lsp_port", -1), 6005, "entry carries lsp_port")

	# 2. WS port stays distinct from the LSP port; core keys present.
	h.eq(e.get("port", -1), 6550, "entry carries ws port (distinct from lsp_port)")
	h.eq(e.get("token_path", ""), "tok", "entry carries token_path")
	h.ok(e.has("_key") and e.has("pid") and e.has("started_at"),
			"entry carries core keys (_key/pid/started_at)")
	h.ok(e.get("runtime_port") == null, "no runtime → runtime_port null")

	# 3. A custom (non-default) LSP port + an active runtime flow through unchanged.
	var e2 := RegistryEntryFile.build_entry("res://proj", 6551, "tok", "127.0.0.1", 6010, 6570, 4242)
	h.eq(e2.get("lsp_port", -1), 6010, "custom lsp_port flows through")
	h.eq(e2.get("runtime_port", -1), 6570, "runtime_port preserved when set")

	print("")


# --- RegistryEntryFile write/read/delete round-trip (concern 039 C2) -------
# The path-keyed atomic I/O leaf: a write then read returns the same dict; a
# delete removes the file so a subsequent read is empty; reading a path that was
# never written is empty too. Uses a user:// temp path and cleans up after.
static func _test_registry_entry_file_io(h) -> void:
	h.begin("RegistryEntryFile write/read/delete")

	var tmp := "user://_test_registry_entry_file_%d.json" % OS.get_process_id()
	# Start clean in case a prior aborted run left the file behind.
	RegistryEntryFile.delete(tmp)

	# 1. Reading a path that was never written → empty dict.
	h.eq(RegistryEntryFile.read(tmp), {}, "read(nonexistent) → {}")

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
	h.eq(got.size(), entry.size(), "write then read → same field count")
	h.eq(got.get("_key", ""), "res://proj", "round-trip: _key preserved")
	h.eq(int(got.get("port", -1)), 6550, "round-trip: port (JSON floats ints → int())")
	h.eq(got.get("token_path", ""), "tok", "round-trip: token_path preserved")
	h.ok(got.get("runtime_port", 0) == null, "round-trip: runtime_port null preserved")

	# 3. delete → the file is gone, so read returns empty again.
	RegistryEntryFile.delete(tmp)
	h.eq(RegistryEntryFile.read(tmp), {}, "delete then read → {}")

	print("")


# --- RegistryClient entry merge (concern 037, direction b) -----------------
# The editor process owns entries/<hash>.json; its runtime child owns
# entries/<hash>.runtime.json (one writer per file — no shared RMW). The rebuild
# merges them by _key: runtime_port/runtime_pid overlay the editor base. This
# pins the pure merge so the aggregate projects.json shape stays identical to the
# pre-split single-file layout the server reads.
static func _test_registry_merge(h) -> void:
	h.begin("RegistryClient entry merge")

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
	h.eq(row.get("runtime_port", -1), 6570, "overlay: runtime_port from runtime file")
	h.eq(row.get("runtime_pid", -1), 4242, "overlay: runtime_pid from runtime file")
	# Editor-owned fields are NOT clobbered by the runtime file's placeholders.
	h.eq(row.get("port", -99), 6550, "overlay: editor port preserved (not -1)")
	h.eq(row.get("token_path", "x"), "tok", "overlay: editor token_path preserved (not empty)")
	h.eq(row.get("lsp_port", -1), 6005, "overlay: editor lsp_port preserved (not null)")
	h.ok(not row.has("_key"), "overlay: _key erased from row")

	# 2. Runtime-only entry (no editor base) — full runtime shape stands in, and
	#    it is schema-complete: port -1, token_path "", and godot_version present
	#    (the old self-heal shim omitted godot_version — concern 037 Low note).
	var only: Dictionary = RegistryProjection.merge_by_path([], [runtime_entry])
	var orow: Dictionary = only.get("res://proj", {})
	h.eq(orow.get("runtime_port", -1), 6570, "runtime-only: runtime_port present")
	h.eq(orow.get("port", -99), -1, "runtime-only: port -1")
	h.eq(orow.get("token_path", "x"), "", "runtime-only: token_path empty")
	h.ok(orow.has("godot_version"), "runtime-only: godot_version present (schema-complete)")
	h.eq(orow.get("lsp_port", -99), null, "runtime-only: lsp_port null")
	h.ok(not orow.has("_key"), "runtime-only: _key erased")

	# 3. Editor-only entry (no runtime overlay) — runtime fields stay the editor
	#    base's null; the row is the editor entry verbatim minus _key.
	var eonly: Dictionary = RegistryProjection.merge_by_path([editor_entry], [])
	var erow: Dictionary = eonly.get("res://proj", {})
	h.eq(erow.get("runtime_port", -99), null, "editor-only: runtime_port null")
	h.eq(erow.get("runtime_pid", -99), null, "editor-only: runtime_pid null")
	h.eq(erow.get("port", -99), 6550, "editor-only: editor port preserved")
	h.ok(not erow.has("_key"), "editor-only: _key erased")

	# 4. clear_runtime semantics: dropping the runtime file removes the overlay —
	#    re-merging without it returns the editor base (runtime fields back to null).
	var cleared: Dictionary = RegistryProjection.merge_by_path([editor_entry], [])
	h.eq(cleared.get("res://proj", {}).get("runtime_port", -99), null,
		"clear: overlay gone → runtime_port back to null")

	print("")
