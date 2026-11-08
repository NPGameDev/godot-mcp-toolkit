@tool
extends RefCounted
## Unit tests for the editor-start update window: its text (the version, the deleted-files
## warning, and the changed files it names up to its limit), the label and link of its
## What's in this update button, and that the shown window never takes the editor's
## dialogs under it. Its buttons need the editor: the update GUI suite
## (test/update_gui_driver/, run by scripts/test_framework/update_gui.sh) covers them.
## Also that the text adds a line only when installing would move the .mcp.json pin.

const Testing := preload("res://test/units/testing.gd")
const UpdatePrompt := preload("res://addons/godot_mcp_toolkit/ui/update/update_prompt.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const ServerPinMoveTests := preload("res://test/units/server_pin_move_tests.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

const _OFFERED_SERVER := "9.9.9"

const _TEXT := ("Godot MCP Toolkit 1.2.0 is available. Install it now?\n\n"
		+ "Update downloads it from the toolkit's GitHub releases. The update installs when the "
		+ "editor restarts or closes, and Godot 4.4 and later restart on their own when no script "
		+ "has unsaved edits, no game is running and no open scene is untitled. Save your work "
		+ "first: restarting from the dock stops a running game and can't "
		+ "ask about every unsaved file.\n\n"
		+ "The new files show up in version control; commit them so everyone on the project "
		+ "runs the same version.")
const _KEPT_COPY_TEXT := ("\n\nThe toolkit keeps a copy of the current version until the next update is staged. "
		+ "If Keep Backup is off in Project Settings, it deletes the copy once this update installs.")


static func run(testing: Testing, tree: SceneTree) -> void:
	_test_text(testing)
	_test_deletes_other_files(testing)
	_test_whats_new(testing)
	_test_never_adopts_editor_dialogs(testing, tree)
	_test_pin_move_line_only_when_a_pin_moves(testing, tree)
	_test_pin_move_line_needs_a_new_server(testing, tree)
	_test_pin_move_line_keeps_the_file_list_last(testing)


# Through a real installer holding a verified release that recommends another server,
# and a real pin move reading the project's .mcp.json. The rows pin whether the line
# shows and the versions it names, not its wording.
static func _test_pin_move_line_only_when_a_pin_moves(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update prompt: the window adds a line only when a pin would move")
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	var saved := ServerPinMoveTests.install_project(ServerPinMoveTests.document_at(compatible))
	var world := UpdateFixtures.begin_world("prompt_pin_move", "1.9.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key(), "4.2", _OFFERED_SERVER)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var pin_move := ServerPinMoveTests.PinMoveStandIn.new()

	var movable := UpdatePrompt.offer_text(installer, pin_move)
	var no_pin_move := UpdatePrompt.offer_text(installer)
	ServerPinMoveTests.restore_project(saved)
	saved = ServerPinMoveTests.install_project(ServerPinMoveTests.document_at("0.0.9"))
	var hand_set := UpdatePrompt.offer_text(installer, pin_move)
	ServerPinMoveTests.restore_project(saved)
	saved = ServerPinMoveTests.install_project(ServerPinMoveTests.document_at(compatible))
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "latest")
	var by_setting := UpdatePrompt.offer_text(installer, pin_move)
	ProjectSettings.set_setting(ServerPinPolicy.SERVER_VERSION_SETTING, "")
	var by_local := ServerPinMoveTests.PinMoveStandIn.new()
	by_local.local_path = "/dev/godot-mcp-server/dist/index.js"
	var local := UpdatePrompt.offer_text(installer, by_local)
	ServerPinMoveTests.restore_project(saved)
	var bare_document := ServerPinMoveTests.document_at(compatible).replace(
			ServerPinPolicy.RELEASE_PACKAGE + "@" + compatible, ServerPinPolicy.RELEASE_PACKAGE)
	saved = ServerPinMoveTests.install_project(bare_document)
	var unversioned := UpdatePrompt.offer_text(installer, pin_move)
	var base := UpdatePrompt.text_for("1.9.0", installer.changed_files(), not installer.discarded_files().is_empty())
	UpdateFixtures.end_world(world, nodes)
	ServerPinMoveTests.restore_project(saved)

	testing.eq(movable.split("\n\n").size(), base.split("\n\n").size() + 1, "a pin that would move → one more paragraph")
	testing.ok(compatible in movable and _OFFERED_SERVER in movable, "naming the server now and the one it moves to")
	testing.eq(no_pin_move, base, "no pin move → the base text")
	testing.eq(hand_set, base, "a pin set by hand → the base text")
	testing.eq(by_setting, base, "a version setting → the base text")
	testing.eq(local, base, "a local server path → the base text")
	testing.eq(unversioned, base, "an entry with no version → the base text")
	print("")


static func _test_pin_move_line_needs_a_new_server(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update prompt: a release that recommends no other server adds no line")
	var compatible := VersionUtils.COMPATIBLE_SERVER_VERSION
	var saved := ServerPinMoveTests.install_project(ServerPinMoveTests.document_at(compatible))
	var pin_move := ServerPinMoveTests.PinMoveStandIn.new()
	var same_server := _offer_text_for_release(tree, "prompt_same_server", compatible, pin_move)
	var no_server := _offer_text_for_release(tree, "prompt_no_server", "", pin_move)
	ServerPinMoveTests.restore_project(saved)
	testing.eq(same_server["text"], same_server["base"], "the manifest names the same server → the base text")
	testing.eq(no_server["text"], no_server["base"], "the manifest names no server → the base text")
	print("")


static func _test_pin_move_line_keeps_the_file_list_last(testing: Testing) -> void:
	testing.begin("Update prompt: the pin line sits before the changed-file list")
	var text := UpdatePrompt.text_for("1.2.0", PackedStringArray(["core/a.gd"]), false,
			{"from": "1.1.2", "to": _OFFERED_SERVER})
	testing.ok(text.find(_OFFERED_SERVER) < text.find("core/a.gd"), "the pin line → before the list")
	testing.ok(text.ends_with("  core/a.gd"), "the list → last")
	print("")


# The window's text and the text with no pin move, for a verified release whose manifest
# names `compatible_server`.
static func _offer_text_for_release(tree: SceneTree, purpose: String, compatible_server: String,
		pin_move: ServerPinMoveTests.PinMoveStandIn) -> Dictionary:
	var world := UpdateFixtures.begin_world(purpose, "1.9.0", "ask", "1.1.0")
	UpdateFixtures.keep_verified(world["updates"], "1.9.0", {"core/a.gd": "new"}, UpdateFixtures.key(), "4.2", compatible_server)
	var nodes := UpdateFixtures.start_world(world, tree)
	var installer: UpdateInstaller = nodes["installer"]
	var offered := {"text": UpdatePrompt.offer_text(installer, pin_move), "base": UpdatePrompt.offer_text(installer)}
	UpdateFixtures.end_world(world, nodes)
	return offered


static func _test_text(testing: Testing) -> void:
	testing.begin("Update prompt: the window's text")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray()), _TEXT, "no changed files → the version and what installing does")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray(["core/a.gd"])), _TEXT + _KEPT_COPY_TEXT
			+ "\n\n1 toolkit file was changed in this project, and installing replaces it:\n  core/a.gd",
			"one changed file → named")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray(["core/a.gd", "core/b.gd"])), _TEXT + _KEPT_COPY_TEXT
			+ "\n\n2 toolkit files were changed in this project, and installing replaces them:\n  core/a.gd\n  core/b.gd",
			"two changed files → counted and named")
	var nine := PackedStringArray()
	for index: int in 9:
		nine.append("f%d.gd" % index)
	var listed := UpdatePrompt.text_for("1.2.0", nine).split("\n")
	testing.eq(listed[listed.size() - 2], "  f7.gd", "the eighth changed file → the last named")
	testing.eq(listed[listed.size() - 1], "  …", "a ninth → an ellipsis instead")
	print("")


static func _test_deletes_other_files(testing: Testing) -> void:
	testing.begin("Update prompt: files installing would delete get a warning, with no list")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray(), true), _TEXT
			+ "\n\nInstalling replaces the whole addon folder and deletes any other files you added to it.",
			"other files in the addon folder → the warning after the text")
	print("")


static func _test_whats_new(testing: Testing) -> void:
	testing.begin("Update prompt: What's in this update opens the changelog")
	testing.eq(UpdatePrompt.WHATS_NEW_LABEL, "What's in this update", "the button's label")
	testing.eq(UpdatePrompt.whats_new_url("1.2.0"), "https://github.com/NPGameDev/godot-mcp-toolkit/blob/v1.2.0/CHANGELOG.md",
			"1.2.0 → its changelog")
	print("")


# The editor reparents its progress and save dialogs under the last exclusive window,
# and closing the prompt frees whatever is under it.
static func _test_never_adopts_editor_dialogs(testing: Testing, tree: SceneTree) -> void:
	testing.begin("Update prompt: the shown window never takes the editor's dialogs under it")
	var prompt := UpdatePrompt.new()
	var dialog := prompt.open_under(tree.root, "text")
	testing.ok(dialog.visible, "the window is shown")
	testing.ok(tree.root.get_last_exclusive_window() != dialog,
			"the shown prompt never becomes the window the editor parents its dialogs under")
	prompt.teardown()
	print("")
