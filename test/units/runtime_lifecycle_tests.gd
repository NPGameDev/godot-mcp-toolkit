@tool
extends RefCounted
## Headless unit shield for the Mode-B runtime autoload's lifecycle invariants.
## Property and predicate assertions, plus one opted-out server put in the tree;
## no port bind, no editor.

const RuntimeServer := preload("res://addons/godot_mcp_toolkit/runtime/mcp_runtime_server.gd")
const RegistryPaths := preload("res://addons/godot_mcp_toolkit/registry/store/registry_paths.gd")

# The public opt-out variable (contract C10), spelled out so the test pins the name.
const _ENV_RUNTIME := "GODOT_MCP_RUNTIME"
# A scratch base for the registry, so the test never rewrites the entry of a game
# this project is really running.
const _SCRATCH_REGISTRY_BASE := "user://runtime_lifecycle_registry"


## [param tree] is the runner itself: Engine.get_main_loop() is still null while the
## runner's _init runs, and its root joins the tree only after a frame.
static func run(testing, tree: SceneTree) -> void:
	_test_process_mode_always(testing)
	_test_runtime_opt_out(testing)
	await _test_opted_out_run_keeps_runtime_entry(testing, tree)


# The runtime WebSocket server must keep polling while the game tree is paused (a
# pause menu / gameplay-pausing quit dialog). PROCESS_MODE_ALWAYS keeps its
# _process → pump() loop running under get_tree().paused; the Node default
# (PAUSABLE) would freeze every runtime tool until the game unpaused. Assert the
# node carries that mode from construction so a pause can never freeze Mode B.
static func _test_process_mode_always(testing) -> void:
	testing.begin("runtime server — PROCESS_MODE_ALWAYS (pause-immune)")
	var server := RuntimeServer.new()
	testing.eq(server.process_mode, Node.PROCESS_MODE_ALWAYS,
		"runtime autoload is PROCESS_MODE_ALWAYS so it keeps polling while the tree is paused")
	server.free()
	print("")


# GODOT_MCP_RUNTIME=0 / false / off keeps a scripted or headless run of the project
# from binding a port and taking the project's runtime entry. Unset, empty, or any
# other value must leave the server on, so the default launch is unchanged.
static func _test_runtime_opt_out(testing) -> void:
	testing.begin("runtime server — GODOT_MCP_RUNTIME opt-out")
	for value: String in ["0", "false", "off", "FALSE", "Off", " 0 "]:
		testing.ok(RuntimeServer.is_opted_out(value), "\"%s\" turns the runtime server off" % value)
	for value: String in ["", "1", "true", "on", "no", "00"]:
		testing.ok(not RuntimeServer.is_opted_out(value), "\"%s\" leaves the runtime server on" % value)
	print("")


# An opted-out run enters the tree inert, and its exit leaves the project's
# runtime entry alone: that entry belongs to the game the MCP tools started, and
# deleting it makes the bridge lose that game. The registry points at a scratch
# directory for the test, and the variables are restored before asserting.
static func _test_opted_out_run_keeps_runtime_entry(testing, tree: SceneTree) -> void:
	testing.begin("runtime server — an opted-out run keeps another run's runtime entry")
	await tree.process_frame
	var base_var := _registry_base_variable()
	var saved_base := _save_env(base_var)
	var saved_opt_out := _save_env(_ENV_RUNTIME)
	# Resolved once, before the redirect: user:// resolves through base_var, so
	# resolving it after would name a directory inside the scratch base.
	var scratch_base := ProjectSettings.globalize_path(_SCRATCH_REGISTRY_BASE)
	OS.set_environment(base_var, scratch_base)
	OS.set_environment(_ENV_RUNTIME, "0")
	var entry_path := RegistryPaths.runtime_entry_file_path()
	var foreign_entry := JSON.stringify({"pid": 4242, "runtime_port": 6599}).to_utf8_buffer()
	var entry_file := FileAccess.open(entry_path, FileAccess.WRITE)
	if entry_file != null:
		entry_file.store_buffer(foreign_entry)
		entry_file.close()

	var server := RuntimeServer.new()
	tree.root.add_child(server)
	var entered_tree := server.is_inside_tree()
	var transport_built := server._transport != null
	var processing := server.is_processing()
	tree.root.remove_child(server)
	server.free()
	var entry_kept := FileAccess.file_exists(entry_path) \
		and FileAccess.get_file_as_bytes(entry_path) == foreign_entry

	_remove_tree(scratch_base)
	_restore_env(base_var, saved_base)
	_restore_env(_ENV_RUNTIME, saved_opt_out)

	testing.ok(entry_file != null, "the foreign runtime entry was written")
	testing.ok(entered_tree, "the opted-out server entered the tree")
	testing.ok(not transport_built, "an opted-out run builds no transport")
	testing.ok(not processing, "an opted-out run does not process")
	testing.ok(entry_kept, "an opted-out run's exit leaves another run's runtime entry unchanged")
	print("")


# The variable RegistryPaths roots the registry directory in on this OS.
static func _registry_base_variable() -> String:
	match OS.get_name():
		"Windows":
			return "APPDATA"
		"macOS":
			return "HOME"
		_:
			return "XDG_DATA_HOME"


# Returns [had_variable, value] for _restore_env.
static func _save_env(variable: String) -> Array:
	return [OS.has_environment(variable), OS.get_environment(variable)]


static func _restore_env(variable: String, saved: Array) -> void:
	if bool(saved[0]):
		OS.set_environment(variable, str(saved[1]))
	else:
		OS.unset_environment(variable)


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub: String in dir.get_directories():
		_remove_tree(path.path_join(sub))
	for file_name: String in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file_name))
	DirAccess.remove_absolute(path)
