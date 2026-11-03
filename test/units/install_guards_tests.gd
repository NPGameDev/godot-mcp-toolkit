@tool
extends RefCounted
## Unit tests for the install guards: each refusal from literal facts, their order,
## the headless override, the sentences shown to the user, and the facts this
## repository's own project reports.

const Testing := preload("res://test/units/testing.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")


static func run(testing) -> void:
	_test_refusals(testing)
	_test_order(testing)
	_test_descriptions(testing)
	_test_repository_facts(testing)
	_test_linked_folder_fact(testing)


# Godot 4.2 on Windows shows no link; everywhere else the guard refuses before any swap.
static func _test_linked_folder_fact(testing: Testing) -> void:
	testing.begin("Install guards: a toolkit folder that is a link")
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("guards_link"))
	var target := root.path_join("target")
	var link := root.path_join("godot_mcp_toolkit")
	FolderFiles.write_checked(target.path_join("plugin.cfg"), "abc".to_utf8_buffer())
	var made := UpdateFixtures.make_folder_link(link, target)
	var through_link := InstallGuards.facts(link)
	var real := InstallGuards.facts(target)
	var shows_links := OS.get_name() != "Windows" or DirAccess.open("user://").has_method("is_link")
	FolderFiles.remove_tree(link)
	FolderFiles.remove_tree(root)
	testing.ok(not bool(real["linked_folder"]), "a real folder → not linked")
	testing.ok(not bool(InstallGuards.facts()["linked_folder"]), "this repository's folder → not linked")
	if made:
		testing.eq(bool(through_link["linked_folder"]), shows_links, "a link → linked, wherever a link shows")
	else:
		print("  SKIP: no folder link can be made here")
	print("")


static func _test_refusals(testing) -> void:
	testing.begin("Install guards: each refusal")
	testing.eq(InstallGuards.refusal({}), "", "no fact set → may install")
	testing.eq(InstallGuards.refusal({"toolkit_repository": true}), "toolkit_repository", "the toolkit's repository → refused")
	testing.eq(InstallGuards.refusal({"linked_folder": true}), "linked_folder", "a linked folder → refused")
	testing.eq(InstallGuards.refusal({"version_control_folder": true}), "version_control_folder", "a git folder → refused")
	testing.eq(InstallGuards.refusal({"headless": true}), "headless", "a headless editor → refused")
	testing.eq(InstallGuards.refusal({"headless": true, "headless_allowed": true}), "", "a headless editor with the override → may install")
	testing.eq(InstallGuards.refusal({"headless_allowed": true}), "", "the override alone → may install")
	print("")


static func _test_order(testing) -> void:
	testing.begin("Install guards: the first rule broken is the one named")
	testing.eq(InstallGuards.refusal({"headless": true, "version_control_folder": true, "toolkit_repository": true}),
			"toolkit_repository", "repository before git folder before headless")
	testing.eq(InstallGuards.refusal({"headless": true, "version_control_folder": true}), "version_control_folder",
			"git folder before headless")
	print("")


static func _test_descriptions(testing) -> void:
	testing.begin("Install guards: the sentence for each refusal")
	testing.eq(InstallGuards.describe("toolkit_repository"),
			"This project is the toolkit's own repository; a release would overwrite its source.", "repository")
	testing.eq(InstallGuards.describe("linked_folder"), "The toolkit's folder is a link to another place.", "link")
	testing.eq(InstallGuards.describe("version_control_folder"),
			"The toolkit's folder is a git checkout or submodule; update it with git.", "git folder")
	testing.eq(InstallGuards.describe("headless"), "A headless editor never installs updates.", "headless")
	testing.eq(InstallGuards.describe(""), "", "no refusal → no sentence")
	print("")


# The unit suite runs in the toolkit's own repository, headless.
static func _test_repository_facts(testing) -> void:
	testing.begin("Install guards: the facts of this repository")
	var facts := InstallGuards.facts()
	testing.ok(bool(facts["toolkit_repository"]), "the repository's markers → toolkit_repository")
	testing.ok(bool(facts["headless"]), "the headless runner → headless")
	testing.eq(InstallGuards.refusal(facts), "toolkit_repository", "so the repository refuses first")
	print("")
