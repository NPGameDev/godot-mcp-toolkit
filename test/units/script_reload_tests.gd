@tool
extends RefCounted
## The shared reload of a script changed on disk (commands/editor_helpers.gd): the
## compile gate, a reload that fails, a file that matches the cached script, the
## toolkit's own paths, the reload a script write runs, and the reload its undo and
## redo run through the undo_helpers node. Drives user:// fixtures rewritten between
## loads; no editor is needed. These cases call the helper directly, so they cannot run
## against a toolkit without it; the live probe covers the same behaviour through the
## tools.

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const UndoRedoHelpers := preload("res://addons/godot_mcp_toolkit/scene/undo_redo_helpers.gd")

const GATE_FIXTURE := "user://script_reload_gate_fixture.gd"
const BROKEN_FIRST_FIXTURE := "user://script_reload_broken_first_fixture.gd"
const FAILED_RELOAD_FIXTURE := "user://script_reload_failed_reload_fixture.gd"
const UNCHANGED_FIXTURE :="user://script_reload_unchanged_fixture.gd"
const WRITE_FIXTURE := "user://script_reload_write_fixture.gd"
const UNDO_FIXTURE := "user://script_reload_undo_fixture.gd"
const NEVER_LOADED_FIXTURE := "user://script_reload_never_loaded_fixture.gd"
const SHADER_FIXTURE := "user://script_reload_shader_fixture.gdshader"

const _BROKEN_SOURCE := "@tool\nextends Node\n\n\nfunc version() -> int:\n\treturn = 1\n"


static func run(testing) -> void:
	_test_compile_gate(testing)
	_test_broken_then_fixed_in_cache(testing)
	_test_failed_reload_retries(testing)
	_test_unchanged_file(testing)
	_test_reload_decision(testing)
	_test_reload_after_write(testing)
	_test_undo_and_redo_reload(testing)


static func _test_compile_gate(testing) -> void:
	testing.begin("script reload: a source that does not compile never replaces the cached script")
	_write_source(GATE_FIXTURE, _version_source(1))
	var script: Script = ResourceLoader.load(GATE_FIXTURE)
	var running := Node.new()
	running.set_script(script)

	_write_source(GATE_FIXTURE, _BROKEN_SOURCE)
	var refused := Helpers.reload_script_from_disk(script)
	testing.ok(not bool(refused["reloaded"]), "the broken source is not reloaded")
	testing.ok(str(refused["compile_error"]) != "", "the outcome says why")
	testing.eq(running.call("version"), 1, "the node keeps running version 1")
	testing.eq(script.source_code, _version_source(1), "the cached script keeps its source")

	_write_source(GATE_FIXTURE, _version_source(3))
	var fixed := Helpers.reload_script_from_disk(script)
	testing.ok(bool(fixed["reloaded"]), "the fixed source reloads on the next call")
	testing.eq(str(fixed["compile_error"]), "", "a reload that applied carries no error")
	testing.eq(running.call("version"), 3, "the node runs the fixed version 3")

	running.free()
	_remove(GATE_FIXTURE)
	print("")


# The first load of a file that does not compile caches a broken script. Fixing the
# file must reach it on the next reload.
static func _test_broken_then_fixed_in_cache(testing) -> void:
	testing.begin("script reload: a script cached broken reloads once its file is fixed")
	_write_source(BROKEN_FIRST_FIXTURE, _BROKEN_SOURCE)
	var printed_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	var script: Script = ResourceLoader.load(BROKEN_FIRST_FIXTURE)
	Engine.print_error_messages = printed_errors
	testing.ok(script != null, "the loader hands back the broken script")
	if script == null:
		_remove(BROKEN_FIRST_FIXTURE)
		return
	var unchanged := Helpers.reload_script_from_disk(script)
	testing.ok(not bool(unchanged["reloaded"]) and str(unchanged["compile_error"]) == "",
			"a broken file that matches the cache is left alone")

	_write_source(BROKEN_FIRST_FIXTURE, _version_source(2))
	var fixed := Helpers.reload_script_from_disk(script)
	testing.ok(bool(fixed["reloaded"]), "the fixed file reloads")
	var fresh := Node.new()
	fresh.set_script(ResourceLoader.load(BROKEN_FIRST_FIXTURE))
	testing.eq(fresh.call("version"), 2, "a node set afterwards runs version 2")

	fresh.free()
	_remove(BROKEN_FIRST_FIXTURE)
	print("")


# A reload can fail after the compile check passed. The caller's judged source stands in
# for that check here: it skips the judge, so the engine's own reload meets the broken
# file. The cached script must keep its source, so the next call checks the file again.
static func _test_failed_reload_retries(testing) -> void:
	testing.begin("script reload: a reload that fails keeps the cached source, so the next call retries")
	_write_source(FAILED_RELOAD_FIXTURE, _version_source(1))
	var script: Script = ResourceLoader.load(FAILED_RELOAD_FIXTURE)
	var running := Node.new()
	running.set_script(script)

	_write_source(FAILED_RELOAD_FIXTURE, _BROKEN_SOURCE)
	var printed_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	var failed := Helpers.reload_script_from_disk(script, _BROKEN_SOURCE)
	Engine.print_error_messages = printed_errors
	testing.ok(not bool(failed["reloaded"]), "the failed reload is not reported as applied")
	testing.ok(str(failed["compile_error"]).begins_with("the reload failed"), "the outcome says the reload failed")
	testing.eq(script.source_code, _version_source(1), "the cached script keeps its previous source")
	# Checked before the call: a call into an invalid script aborts this test without a FAIL.
	testing.ok(script.can_instantiate(), "the cached script is valid again")
	testing.eq(running.call("version"), 1, "the node keeps running version 1")

	var retried := Helpers.reload_script_from_disk(script)
	testing.ok(not bool(retried["reloaded"]) and str(retried["compile_error"]) != "",
			"the next call checks the unchanged broken file again and refuses it")

	_write_source(FAILED_RELOAD_FIXTURE, _version_source(3))
	var fixed := Helpers.reload_script_from_disk(script)
	testing.ok(bool(fixed["reloaded"]), "the fixed file reloads")
	testing.eq(running.call("version"), 3, "the node runs the fixed version 3")

	running.free()
	_remove(FAILED_RELOAD_FIXTURE)
	print("")


static func _test_unchanged_file(testing) -> void:
	testing.begin("script reload: a file that matches the cached script is not reloaded")
	_write_source(UNCHANGED_FIXTURE, _version_source(1))
	var script: Script = ResourceLoader.load(UNCHANGED_FIXTURE)
	var outcome := Helpers.reload_script_from_disk(script)
	testing.ok(not bool(outcome["reloaded"]), "no reload")
	testing.eq(str(outcome["compile_error"]), "", "no error")
	_remove(UNCHANGED_FIXTURE)
	print("")


static func _test_reload_decision(testing) -> void:
	testing.begin("script reload: the decision skips the toolkit's own scripts")
	testing.ok(Helpers.should_reload_script("res://player.gd", "new", "old"),
			"a project script whose file changed → reload")
	testing.ok(not Helpers.should_reload_script("res://addons/godot_mcp_toolkit/core/modules.gd", "new", "old"),
			"a toolkit script whose file changed → no reload")
	testing.ok(Helpers.should_reload_script("res://addons/godot_mcp_toolkit_extras/x.gd", "new", "old"),
			"a sibling addon whose name extends the toolkit's → reload")
	testing.ok(not Helpers.should_reload_script("res://player.gd", "same", "same"),
			"an unchanged file → no reload")
	testing.ok(not Helpers.should_reload_script("res://player.gd", "", "old"),
			"an empty or unreadable file → no reload")
	print("")


# script_write and script_edit call reload_cached_script with the content they wrote and
# just judged valid.
static func _test_reload_after_write(testing) -> void:
	testing.begin("script reload: a write reloads the cached script its node runs")
	_write_source(WRITE_FIXTURE, _version_source(1))
	var running := Node.new()
	running.set_script(ResourceLoader.load(WRITE_FIXTURE))

	var written := _version_source(2)
	_write_source(WRITE_FIXTURE, written)
	var outcome := Helpers.reload_cached_script(WRITE_FIXTURE, written)
	testing.ok(bool(outcome["reloaded"]), "the write reloads the cached script")
	testing.eq(running.call("version"), 2, "the node already running it runs version 2")

	_write_source(NEVER_LOADED_FIXTURE, _version_source(1))
	testing.ok(not bool(Helpers.reload_cached_script(NEVER_LOADED_FIXTURE)["reloaded"]),
			"a script the editor never loaded is left for its first load")
	_write_source(SHADER_FIXTURE, "shader_type canvas_item;\n")
	var shader: Resource = ResourceLoader.load(SHADER_FIXTURE)
	testing.ok(shader != null and ResourceLoader.has_cached(SHADER_FIXTURE), "the shader fixture is cached")
	# A call that fails at runtime returns an empty Dictionary, so read the key with a
	# default that fails the check rather than aborting this test.
	var shader_outcome := Helpers.reload_cached_script(SHADER_FIXTURE)
	testing.ok(not bool(shader_outcome.get("reloaded", true)),
			"a cached resource that is not a script is left alone")

	running.free()
	_remove(WRITE_FIXTURE)
	_remove(NEVER_LOADED_FIXTURE)
	_remove(SHADER_FIXTURE)
	print("")


static func _test_undo_and_redo_reload(testing) -> void:
	testing.begin("script reload: the undo and redo of a write reload the cached script")
	_write_source(UNDO_FIXTURE, _version_source(2))
	var running := Node.new()
	running.set_script(ResourceLoader.load(UNDO_FIXTURE))
	var undo_helpers := UndoRedoHelpers.new()

	undo_helpers._write_file_silent(UNDO_FIXTURE, _version_source(1))
	testing.eq(running.call("version"), 1, "undo restores the file and the node runs version 1")
	undo_helpers._write_file_silent(UNDO_FIXTURE, _version_source(2))
	testing.eq(running.call("version"), 2, "redo writes it again and the node runs version 2")
	undo_helpers._write_file_silent(UNDO_FIXTURE, _BROKEN_SOURCE)
	testing.eq(running.call("version"), 2, "an undo to a source that does not compile keeps version 2")

	undo_helpers.free()
	running.free()
	_remove(UNDO_FIXTURE)
	print("")


static func _version_source(version: int) -> String:
	return "@tool\nextends Node\n\n\nfunc version() -> int:\n\treturn %d\n" % version


static func _write_source(path: String, source: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(source)
	file.close()


static func _remove(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
