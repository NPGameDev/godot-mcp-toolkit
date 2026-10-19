@tool
extends RefCounted
## node.set_script and a script changed on disk: ResourceLoader.load() hands back
## the cached Script, so node.set_script must bring it up to date before it sets
## it. Drives the reload node.set_script calls, commands/editor_helpers'
## reload_script_from_disk, against a user:// script rewritten between two loads;
## no editor is needed.

const Helpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")

const FIXTURE := "user://node_set_script_stale_fixture.gd"


static func run(testing) -> void:
	_test_reload_after_rewrite(testing)


static func _test_reload_after_rewrite(testing) -> void:
	testing.begin("node.set_script runs the script's code as it is on disk")
	_write_version(1)
	var first: Script = ResourceLoader.load(FIXTURE)
	var running := Node.new()
	running.set_script(first)
	testing.eq(running.call("version"), 1, "version 1 runs")

	_write_version(2)
	var cached: Script = ResourceLoader.load(FIXTURE)
	testing.ok(cached == first, "the cache hands back the Script loaded first")
	Helpers.reload_script_from_disk(cached)
	testing.eq(running.call("version"), 2, "the node already running it runs version 2")

	var fresh := Node.new()
	fresh.set_script(ResourceLoader.load(FIXTURE))
	testing.eq(fresh.call("version"), 2, "a node set afterwards runs version 2")

	running.free()
	fresh.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE))
	print("")


static func _write_version(version: int) -> void:
	var file := FileAccess.open(FIXTURE, FileAccess.WRITE)
	file.store_string("@tool\nextends Node\n\n\nfunc version() -> int:\n\treturn %d\n" % version)
	file.close()
