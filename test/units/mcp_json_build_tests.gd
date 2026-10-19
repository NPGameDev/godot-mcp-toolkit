@tool
extends RefCounted
## Unit tests for the pure per-OS .mcp.json server-entry builder
## (MCPJsonSync.build_server_entry): the bare npx (release) / node (dev) shapes on
## macOS, Linux, and any unknown OS; the Windows cmd /c npx + node-dev shapes; and
## the entry boundary — the builder emits only {command, args}, never an env. Also
## covers the env layering (MCPJsonSync.merge_server_env): the template base plus an
## existing file's user GODOT_MCP_* keys, a first-create from the template alone, and
## the merge never mutating its inputs. The file-level write is covered against a
## fixture .mcp.json at the project root (restored afterwards): other servers and
## top-level keys survive (MCPJsonSync.merge_document), a malformed file is never
## written, and a confirm is due only for a differing toolkit entry.

const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")

const _PKG := "@npgamedev/godot-mcp-server"
const _DEV := "/Users/dev/godot-mcp-server/dist/index.js"


static func run(testing) -> void:
	_test_macos_release(testing)
	_test_macos_dev(testing)
	_test_windows_release(testing)
	_test_windows_dev(testing)
	_test_linux_release(testing)
	_test_linux_dev(testing)
	_test_unknown_os_defaults_linux(testing)
	_test_refresh_preserves_user_env(testing)
	_test_env_first_create_uses_template(testing)
	_test_env_merge_is_pure(testing)
	_test_write_keeps_other_servers(testing)
	_test_malformed_file_is_never_written(testing)
	_test_merge_document_without_servers_key(testing)
	_test_merge_document_keeps_existing_key_name(testing)
	_test_merge_document_replaces_only_our_entry(testing)
	_test_needs_confirm_only_for_a_differing_entry(testing)
	_test_write_replaces_entry_and_keeps_siblings(testing)
	_test_non_object_servers_counts_as_malformed(testing)
	_test_foreign_godot_mcp_server_survives_write(testing)
	_test_recognisable_alternate_key_is_reused(testing)
	_test_global_install_entry_is_reused_with_its_env(testing)


# macOS release: bare npx — same shape as Linux. A GUI-launched client resolves the
# bare npx to a version-manager node via its captured shell env; no env is emitted.
static func _test_macos_release(testing) -> void:
	testing.begin("build_server_entry — macOS release (bare npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", "")
	testing.eq(str(entry["command"]), "npx", "command = npx")
	var args: Array = entry["args"]
	testing.eq(args.size(), 2, "release args length 2")
	testing.eq(str(args[0]), "-y", "release arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "release arg 1 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# macOS dev: bare node runs the local dist entry (a GODOT_MCP_DEV_SERVER_PATH override).
static func _test_macos_dev(testing) -> void:
	testing.begin("build_server_entry — macOS dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("macOS", _DEV)
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Windows release: cmd /c npx (npx is a .cmd shim); no env emitted.
static func _test_windows_release(testing) -> void:
	testing.begin("build_server_entry — Windows release (cmd /c npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "")
	testing.eq(str(entry["command"]), "cmd", "command = cmd")
	var args: Array = entry["args"]
	testing.eq(args.size(), 4, "cmd args length 4")
	testing.eq(str(args[0]), "/c", "arg 0 = /c")
	testing.eq(str(args[1]), "npx", "arg 1 = npx")
	testing.eq(str(args[2]), "-y", "arg 2 = -y")
	testing.eq(str(args[3]), _PKG, "arg 3 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Windows dev: node runs the dist entry directly (node is a real exe on PATH).
static func _test_windows_dev(testing) -> void:
	testing.begin("build_server_entry — Windows dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Windows", "C:/x/dist/index.js")
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(args.size(), 1, "dev args length 1")
	testing.eq(str(args[0]), "C:/x/dist/index.js", "dev arg = dist entry")
	print("")


# Linux release: bare npx (no shim).
static func _test_linux_release(testing) -> void:
	testing.begin("build_server_entry — Linux release (bare npx)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", "")
	testing.eq(str(entry["command"]), "npx", "command = npx")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), "-y", "arg 0 = -y")
	testing.eq(str(args[1]), _PKG, "arg 1 = package")
	testing.ok(not entry.has("env"), "builder emits no env")
	print("")


# Linux dev: bare node + dist.
static func _test_linux_dev(testing) -> void:
	testing.begin("build_server_entry — Linux dev (node dist)")
	var entry: Dictionary = MCPJsonSync.build_server_entry("Linux", _DEV)
	testing.eq(str(entry["command"]), "node", "command = node")
	var args: Array = entry["args"]
	testing.eq(str(args[0]), _DEV, "dev arg = dist entry")
	print("")


# An unknown OS falls through to the Linux-style bare command (safe default).
static func _test_unknown_os_defaults_linux(testing) -> void:
	testing.begin("build_server_entry — unknown OS defaults to Linux shape")
	var release: Dictionary = MCPJsonSync.build_server_entry("Haiku", "")
	testing.eq(str(release["command"]), "npx", "unknown OS release = bare npx")
	var dev: Dictionary = MCPJsonSync.build_server_entry("Haiku", _DEV)
	testing.eq(str(dev["command"]), "node", "unknown OS dev = bare node")
	print("")


# Merging an existing file's env over the template base preserves the user's own
# GODOT_MCP_* keys (a port pin here) while keeping the template's config version —
# the layering _build_entry does on every rewrite.
static func _test_refresh_preserves_user_env(testing) -> void:
	testing.begin("merge_server_env — preserves user keys over the template base")
	var template_env := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing_env := {"GODOT_MCP_CONFIG_VERSION": "1", "GODOT_MCP_EDITOR_PORT": "6560"}
	var env: Dictionary = MCPJsonSync.merge_server_env(template_env, existing_env)
	testing.eq(str(env.get("GODOT_MCP_EDITOR_PORT", "")), "6560", "user port pin preserved")
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version present")
	print("")


# A first-time create (no existing file → {} existing env) uses the template base
# alone — GODOT_MCP_CONFIG_VERSION, no stray keys.
static func _test_env_first_create_uses_template(testing) -> void:
	testing.begin("merge_server_env — first create uses template base")
	var env: Dictionary = MCPJsonSync.merge_server_env({"GODOT_MCP_CONFIG_VERSION": "1"}, {})
	testing.eq(str(env.get("GODOT_MCP_CONFIG_VERSION", "")), "1", "config version from template")
	testing.eq(env.size(), 1, "no extra keys on first create")
	print("")


# The merge is pure: neither input is mutated.
static func _test_env_merge_is_pure(testing) -> void:
	testing.begin("merge_server_env — does not mutate inputs")
	var base := {"GODOT_MCP_CONFIG_VERSION": "1"}
	var existing := {"GODOT_MCP_EDITOR_PORT": "6560"}
	MCPJsonSync.merge_server_env(base, existing)
	testing.eq(base.size(), 1, "base env not mutated")
	testing.eq(existing.size(), 1, "existing env not mutated")
	print("")


# A shared .mcp.json: the write keeps the other servers and top-level keys and
# replaces only the toolkit's own entry.
static func _test_write_keeps_other_servers(testing) -> void:
	testing.begin("_build_content — keeps other servers and top-level keys")
	var prior: Variant = _install_fixture(JSON.stringify({
		"mcpServers": {
			"godot-mcp-toolkit": {"command": "old", "args": []},
			"other-server": {"command": "other", "args": ["--flag"]},
		},
		"x-note": "keep me",
	}))
	var document := _parse_document(MCPJsonSync._build_content())
	_restore_fixture(prior)
	var servers: Dictionary = document.get("mcpServers", {})
	testing.ok(servers.has("other-server"), "other server kept")
	testing.eq(str(servers.get("other-server", {}).get("command", "")), "other", "other server untouched")
	testing.eq(str(document.get("x-note", "")), "keep me", "other top-level key kept")
	testing.ok(str(servers.get("godot-mcp-toolkit", {}).get("command", "old")) != "old", "toolkit entry replaced")
	print("")


# A file that exists but is not a JSON object is never written, even when the
# caller passes force_overwrite: the callback reports a refusal and the bytes stay.
static func _test_malformed_file_is_never_written(testing) -> void:
	testing.begin("write_from_template — refuses a malformed file, even forced")
	var malformed_text := "{ \"mcpServers\": { not json"
	var prior: Variant = _install_fixture(malformed_text)
	var report := {"called": false, "ok": true, "message": ""}
	var sink := func(ok: bool, message: String, _severity: int, _tooltip: String) -> void:
		report["called"] = true
		report["ok"] = ok
		report["message"] = message
	MCPJsonSync.write_from_template(true, sink)
	var after := FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path())
	_restore_fixture(prior)
	testing.ok(bool(report["called"]), "callback called")
	testing.ok(not bool(report["ok"]), "reports not-ok")
	testing.ok(str(report["message"]).contains("isn't valid JSON"), "message names the cause")
	testing.eq(after, malformed_text, "file bytes unchanged")
	print("")


# No mcpServers key (or an empty document): the merge creates it with our entry.
static func _test_merge_document_without_servers_key(testing) -> void:
	testing.begin("merge_document — creates mcpServers when absent")
	var entry := {"command": "npx"}
	var existing := {"x-note": "keep"}
	var document: Dictionary = MCPJsonSync.merge_document(existing, "godot-mcp-toolkit", entry)
	var servers: Dictionary = document.get("mcpServers", {})
	testing.eq(servers.keys(), ["godot-mcp-toolkit"], "only our entry under mcpServers")
	testing.eq(str(document.get("x-note", "")), "keep", "top-level key kept")
	testing.ok(not existing.has("mcpServers"), "input not mutated")
	var from_empty: Dictionary = MCPJsonSync.merge_document({}, "godot-mcp-toolkit", entry)
	testing.ok(from_empty.has("mcpServers"), "empty document gains mcpServers")
	print("")


# A file that names the toolkit's server under another key keeps that key; no
# second entry appears under the default name.
static func _test_merge_document_keeps_existing_key_name(testing) -> void:
	testing.begin("merge_document — a non-default toolkit key name is kept")
	var existing := {"mcpServers": {"godot-mcp": {"command": "old"}}}
	var document: Dictionary = MCPJsonSync.merge_document(existing, "godot-mcp", {"command": "new"})
	var servers: Dictionary = document.get("mcpServers", {})
	testing.eq(servers.keys(), ["godot-mcp"], "same single key")
	testing.eq(str(servers["godot-mcp"].get("command", "")), "new", "entry replaced under that key")
	print("")


# Our entry is replaced wholesale; a sibling server (env included) is carried over
# untouched, and the input document is left as it was.
static func _test_merge_document_replaces_only_our_entry(testing) -> void:
	testing.begin("merge_document — replaces our entry, leaves a sibling's env alone")
	var existing := {"mcpServers": {
		"godot-mcp-toolkit": {"command": "old", "env": {"A": "1"}},
		"other-server": {"command": "o", "env": {"B": "2"}},
	}}
	var entry := {"command": "new", "env": {"C": "3"}}
	var document: Dictionary = MCPJsonSync.merge_document(existing, "godot-mcp-toolkit", entry)
	var servers: Dictionary = document["mcpServers"]
	testing.eq(servers["godot-mcp-toolkit"], entry, "our entry replaced")
	testing.eq(servers["other-server"]["env"], {"B": "2"}, "sibling env untouched")
	testing.eq(existing["mcpServers"]["godot-mcp-toolkit"]["command"], "old", "input not mutated")
	print("")


# A confirm is needed only when the file holds a toolkit entry that the write would
# change; the malformed case is refused by the write itself.
static func _test_needs_confirm_only_for_a_differing_entry(testing) -> void:
	testing.begin("needs_overwrite_confirm — only for a differing existing entry")
	var prior: Variant = _install_fixture("{}")
	var current_entry: Dictionary = MCPJsonSync._build_entry()
	_restore_fixture(prior)

	var absent: Variant = _install_fixture("")
	DirAccess.remove_absolute(MCPJsonSync.get_mcp_json_path())
	testing.ok(not MCPJsonSync.needs_overwrite_confirm(), "no file: no confirm")
	_restore_fixture(absent)

	var no_entry: Variant = _install_fixture(JSON.stringify({"mcpServers": {"other-server": {"command": "o"}}}))
	testing.ok(not MCPJsonSync.needs_overwrite_confirm(), "no toolkit entry: no confirm")
	_restore_fixture(no_entry)

	var identical: Variant = _install_fixture(JSON.stringify({"mcpServers": {"godot-mcp-toolkit": current_entry}}))
	testing.ok(not MCPJsonSync.needs_overwrite_confirm(), "identical entry: no confirm")
	_restore_fixture(identical)

	var differing: Variant = _install_fixture(JSON.stringify(
		{"mcpServers": {"godot-mcp-toolkit": {"command": "stale", "args": []}}}))
	testing.ok(MCPJsonSync.needs_overwrite_confirm(), "differing entry: confirm")
	_restore_fixture(differing)

	var malformed: Variant = _install_fixture("{ nope")
	testing.ok(not MCPJsonSync.needs_overwrite_confirm(), "malformed file: refusal owns it, no confirm")
	_restore_fixture(malformed)
	print("")


# End to end through the file: a differing toolkit entry is replaced on disk and
# the sibling server survives.
static func _test_write_replaces_entry_and_keeps_siblings(testing) -> void:
	testing.begin("write_from_template — replaces our entry on disk, keeps siblings")
	var prior: Variant = _install_fixture(JSON.stringify({
		"mcpServers": {
			"godot-mcp-toolkit": {"command": "stale", "args": []},
			"other-server": {"command": "other"},
		},
	}))
	var report := {"ok": false}
	var sink := func(ok: bool, _message: String, _severity: int, _tooltip: String) -> void:
		report["ok"] = ok
	MCPJsonSync.write_from_template(true, sink)
	var document := _parse_document(FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path()))
	_restore_fixture(prior)
	var servers: Dictionary = document.get("mcpServers", {})
	testing.ok(bool(report["ok"]), "write reports ok")
	testing.ok(servers.has("other-server"), "sibling survives")
	testing.ok(str(servers.get("godot-mcp-toolkit", {}).get("command", "stale")) != "stale", "our entry rewritten")
	print("")


# An mcpServers value that is not an object (array, string, null, number) is
# unusable to a client: the file counts as malformed, the write refuses it even
# when forced, and no confirm is offered.
static func _test_non_object_servers_counts_as_malformed(testing) -> void:
	testing.begin("non-object mcpServers — malformed, refused, no confirm")
	for fixture_text in ["{\"mcpServers\": []}", "{\"mcpServers\": \"x\"}", "{\"mcpServers\": null}", "{\"mcpServers\": 3}"]:
		var text: String = fixture_text
		var prior: Variant = _install_fixture(text)
		var report := {"ok": true}
		var sink := func(ok: bool, _message: String, _severity: int, _tooltip: String) -> void:
			report["ok"] = ok
		var malformed: bool = MCPJsonSync.is_malformed()
		var confirm: bool = MCPJsonSync.needs_overwrite_confirm()
		MCPJsonSync.write_from_template(true, sink)
		var after := FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path())
		_restore_fixture(prior)
		testing.ok(malformed, "%s: is malformed" % text)
		testing.ok(not confirm, "%s: no confirm" % text)
		testing.ok(not bool(report["ok"]), "%s: forced write refused" % text)
		testing.eq(after, text, "%s: file bytes unchanged" % text)
	print("")


# A server that only has "godot-mcp" in its name is not the toolkit's: a write
# keeps it untouched, adds our entry under the default key, and does not fold the
# foreign server's env into ours.
static func _test_foreign_godot_mcp_server_survives_write(testing) -> void:
	testing.begin("write_from_template — a foreign godot-mcp server survives")
	var foreign := {"command": "foreign", "args": ["x"], "env": {"GODOT_MCP_FOREIGN": "keep"}}
	var prior: Variant = _install_fixture(JSON.stringify({"mcpServers": {"godot-mcp": foreign}}))
	var confirm: bool = MCPJsonSync.needs_overwrite_confirm()
	var report := {"ok": false}
	var sink := func(ok: bool, _message: String, _severity: int, _tooltip: String) -> void:
		report["ok"] = ok
	MCPJsonSync.write_from_template(false, sink)
	var document := _parse_document(FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path()))
	_restore_fixture(prior)
	var servers: Dictionary = document.get("mcpServers", {})
	testing.ok(not confirm, "no toolkit entry: no confirm")
	testing.ok(bool(report["ok"]), "unconfirmed write goes ahead")
	testing.eq(servers.get("godot-mcp", {}), foreign, "foreign server untouched")
	testing.ok(servers.has("godot-mcp-toolkit"), "our entry added under the default key")
	var env: Dictionary = servers.get("godot-mcp-toolkit", {}).get("env", {})
	testing.ok(not env.has("GODOT_MCP_FOREIGN"), "foreign env not folded into ours")
	print("")


# A non-default key whose entry names our package, or carries our config-version
# marker, is ours: the write replaces it in place and adds no second entry.
static func _test_recognisable_alternate_key_is_reused(testing) -> void:
	testing.begin("write_from_template — a recognisable alternate key is reused")
	var by_args := {"command": "npx", "args": ["-y", "@npgamedev/godot-mcp-server"]}
	var by_env := {"command": "node", "args": ["dist/index.js"], "env": {"GODOT_MCP_CONFIG_VERSION": "1"}}
	for entry in [by_args, by_env]:
		var prior: Variant = _install_fixture(JSON.stringify({"mcpServers": {"godot-mcp": entry}}))
		var confirm: bool = MCPJsonSync.needs_overwrite_confirm()
		var discard := func(_ok: bool, _message: String, _severity: int, _tooltip: String) -> void: pass
		MCPJsonSync.write_from_template(true, discard)
		var document := _parse_document(FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path()))
		_restore_fixture(prior)
		var servers: Dictionary = document.get("mcpServers", {})
		testing.ok(confirm, "recognised entry that differs: confirm")
		testing.eq(servers.keys(), ["godot-mcp"], "replaced in place, no second entry")
	print("")


# A hand-written global-install entry (command is the godot-mcp-server binary) is
# the toolkit's: reused in place with its env pins carried, and the confirm names
# that key.
static func _test_global_install_entry_is_reused_with_its_env(testing) -> void:
	testing.begin("write_from_template — a global-install entry is reused with its env")
	var entry := {"command": "godot-mcp-server", "env": {"GODOT_MCP_EDITOR_PORT": "6561"}}
	var prior: Variant = _install_fixture(JSON.stringify({"mcpServers": {"godot-mcp": entry}}))
	var key: String = MCPJsonSync.get_own_entry_key()
	var discard := func(_ok: bool, _message: String, _severity: int, _tooltip: String) -> void: pass
	MCPJsonSync.write_from_template(true, discard)
	var document := _parse_document(FileAccess.get_file_as_string(MCPJsonSync.get_mcp_json_path()))
	_restore_fixture(prior)
	var servers: Dictionary = document.get("mcpServers", {})
	var env: Dictionary = servers.get("godot-mcp", {}).get("env", {})
	testing.eq(key, "godot-mcp", "own key is the entry's key")
	testing.eq(servers.keys(), ["godot-mcp"], "replaced in place, no second entry")
	testing.eq(str(env.get("GODOT_MCP_EDITOR_PORT", "")), "6561", "env pin carried")
	print("")


# Writes the given text as the project's .mcp.json and returns what was there before
# (its bytes, or null for no file) for _restore_fixture.
static func _install_fixture(text: String) -> Variant:
	var path: String = MCPJsonSync.get_mcp_json_path()
	var prior: Variant = null
	if FileAccess.file_exists(path):
		prior = FileAccess.get_file_as_bytes(path)
	_store_bytes(path, text.to_utf8_buffer())
	return prior


# Puts back what _install_fixture displaced: the old bytes, or no file at all.
static func _restore_fixture(prior: Variant) -> void:
	var path: String = MCPJsonSync.get_mcp_json_path()
	if prior == null:
		DirAccess.remove_absolute(path)
	else:
		_store_bytes(path, prior)


static func _store_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


# Parses the given text without the console noise of JSON.parse_string; {} when it is
# not a JSON object.
static func _parse_document(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	return json.data
