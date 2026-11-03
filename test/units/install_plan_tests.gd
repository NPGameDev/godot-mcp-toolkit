@tool
extends RefCounted
## Unit tests for the install plan: changed files reported, unlisted files named as
## discarded with .import files and the list itself left out, and a folder with no list.

const Testing := preload("res://test/units/testing.gd")
const InstallPlan := preload("res://addons/godot_mcp_toolkit/self_update/install_plan.gd")

const _A := "aa"
const _B := "bb"


static func run(testing: Testing) -> void:
	_test_no_write_or_delete_list(testing)
	_test_discarded(testing)
	_test_changed(testing)
	_test_no_list(testing)


static func _test_no_write_or_delete_list(testing: Testing) -> void:
	testing.begin("Install plan: names no writes and no deletes")
	var plan := InstallPlan.plan({"plugin.cfg": _A}, {"plugin.cfg": _A})
	testing.ok(not plan.has("write"), "no write list")
	testing.ok(not plan.has("delete"), "no delete list")
	print("")


static func _test_discarded(testing: Testing) -> void:
	testing.begin("Install plan: what the swap discards")
	var installed_list := {"plugin.cfg": _A, "old.gd": _A, "gone.gd": _A}
	var installed_files := {"plugin.cfg": _A, "old.gd": _B, "core/mine.gd": _B, "a_mine.gd": _B}
	testing.eq(InstallPlan.plan(installed_list, installed_files)["discarded"], PackedStringArray(["a_mine.gd", "core/mine.gd"]),
			"files the list does not name → named, sorted; listed and already-gone files → not")
	testing.eq(InstallPlan.plan(installed_list, {"icon.svg.import": _B})["discarded"], PackedStringArray(),
			"an engine .import file → not named")
	testing.eq(InstallPlan.plan(installed_list, {"icon.svg.import.bak": _B})["discarded"], PackedStringArray(["icon.svg.import.bak"]),
			"a name that only holds .import → named")
	testing.eq(InstallPlan.plan(installed_list, {"release_files.sha256": _B})["discarded"], PackedStringArray(),
			"the list itself → not named")
	testing.eq(InstallPlan.plan(installed_list, {"core/release_files.sha256": _B})["discarded"], PackedStringArray(["core/release_files.sha256"]),
			"a file of that name in a subfolder → named")
	print("")


static func _test_changed(testing: Testing) -> void:
	testing.begin("Install plan: files changed by hand")
	var plan := InstallPlan.plan({"plugin.gd": _A, "core/b.gd": _A, "core/a.gd": _A},
			{"plugin.gd": _A, "core/b.gd": _B, "core/a.gd": _B, "mine.gd": _B})
	testing.eq(plan["changed"], PackedStringArray(["core/a.gd", "core/b.gd"]),
			"listed files whose content differs → reported, sorted; unlisted files → not")
	print("")


static func _test_no_list(testing: Testing) -> void:
	testing.begin("Install plan: an installed folder with no list")
	var plan := InstallPlan.plan({}, {"old.gd": _A, "icon.svg.import": _A})
	testing.eq(plan["has_list"], false, "the plan says there was no list")
	testing.eq(plan["changed"], PackedStringArray(), "nothing reported changed")
	testing.eq(plan["discarded"], PackedStringArray(["old.gd"]), "every file but .import → named")
	testing.eq(InstallPlan.plan({"plugin.cfg": _A}, {})["has_list"], true, "a folder with a list → the plan says so")
	print("")
