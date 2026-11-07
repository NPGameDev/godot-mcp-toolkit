@tool
extends RefCounted
## Unit tests for the editor-start update window: its text (the version, the deleted-files
## warning, and the changed files it names up to its limit), the label and link of its
## What's in this update button, and that the shown window never takes the editor's
## dialogs under it. Its buttons need the editor: the update GUI suite
## (test/update_gui_driver/, run by scripts/test_framework/update_gui.sh) covers them.

const Testing := preload("res://test/units/testing.gd")
const UpdatePrompt := preload("res://addons/godot_mcp_toolkit/ui/update/update_prompt.gd")

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
