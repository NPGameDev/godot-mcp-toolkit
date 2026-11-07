@tool
extends RefCounted
## Unit tests for the editor-start update window: its text (the version, the deleted-files
## warning, and the changed files it names up to its limit) and the label and link of its
## What's in this update button. The window itself needs the editor: the update GUI suite
## (test/update_gui_driver/, run by scripts/test_framework/update_gui.sh) covers it.

const Testing := preload("res://test/units/testing.gd")
const UpdatePrompt := preload("res://addons/godot_mcp_toolkit/ui/update/update_prompt.gd")

const _TEXT := ("Godot MCP Toolkit 1.2.0 is available. Install it now?\n\n"
		+ "Update downloads it from the toolkit's GitHub releases, then installs it when the "
		+ "editor restarts or closes; Godot 4.4 and later restart on their own when nothing "
		+ "needs saving. Save your work first: the restart stops a running game and can't "
		+ "ask about every unsaved file.\n\n"
		+ "The new files show up in version control; commit them so everyone on the project "
		+ "runs the same version.")
const _KEPT_COPY_TEXT := ("\n\nThe toolkit keeps a copy of the current version until the next update is staged. "
		+ "If Keep Backup is off in Project Settings, it deletes the copy once this update installs.")


static func run(testing: Testing) -> void:
	_test_text(testing)
	_test_deletes_other_files(testing)
	_test_whats_new(testing)


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
