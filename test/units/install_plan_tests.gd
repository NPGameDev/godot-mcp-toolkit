@tool
extends RefCounted
## Unit tests for the install plan: every release file written with plugin.cfg last,
## only listed files the release dropped deleted, .import and unlisted files kept,
## changed files reported, and nothing deleted without an installed list.

const InstallPlan := preload("res://addons/godot_mcp_toolkit/update/install_plan.gd")

const _A := "aa"
const _B := "bb"


static func run(testing) -> void:
	_test_writes(testing)
	_test_deletes(testing)
	_test_changed(testing)
	_test_no_list(testing)


static func _test_writes(testing) -> void:
	testing.begin("Install plan: what it writes")
	var plan := InstallPlan.plan({}, {}, PackedStringArray(["plugin.cfg", "plugin.gd", "core/a.gd"]))
	testing.eq(plan["write"], PackedStringArray(["plugin.gd", "core/a.gd", "plugin.cfg"]),
			"every release file in release order, plugin.cfg moved last")
	print("")


static func _test_deletes(testing) -> void:
	testing.begin("Install plan: what it deletes")
	var installed_list := {"plugin.cfg": _A, "old.gd": _A, "icon.svg.import": _A, "gone.gd": _A}
	var installed_files := {"plugin.cfg": _A, "old.gd": _A, "icon.svg.import": _A, "mine.gd": _B}
	var plan := InstallPlan.plan(installed_list, installed_files, PackedStringArray(["plugin.cfg"]))
	testing.eq(plan["delete"], PackedStringArray(["old.gd"]),
			"a listed file the release dropped → deleted; .import, unlisted and already-gone files → not")
	print("")


static func _test_changed(testing) -> void:
	testing.begin("Install plan: files changed by hand")
	var plan := InstallPlan.plan({"plugin.gd": _A, "core/b.gd": _A, "core/a.gd": _A},
			{"plugin.gd": _A, "core/b.gd": _B, "core/a.gd": _B, "mine.gd": _B}, PackedStringArray(["plugin.gd"]))
	testing.eq(plan["changed"], PackedStringArray(["core/a.gd", "core/b.gd"]),
			"listed files whose content differs → reported, sorted; unlisted files → not")
	print("")


static func _test_no_list(testing) -> void:
	testing.begin("Install plan: an installed folder with no list")
	var plan := InstallPlan.plan({}, {"old.gd": _A}, PackedStringArray(["plugin.cfg"]))
	testing.eq(plan["delete"], PackedStringArray(), "nothing deleted")
	testing.eq(plan["changed"], PackedStringArray(), "nothing reported changed")
	print("")
