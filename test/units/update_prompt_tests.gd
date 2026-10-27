@tool
extends RefCounted
## Unit tests for the editor-start update window's text: the version, and the changed
## files it names up to its limit. The window itself needs the editor; the pull
## request's interactive checks cover it.

const UpdatePrompt := preload("res://addons/godot_mcp_toolkit/ui/update/update_prompt.gd")

const _TEXT := ("Godot MCP Toolkit 1.2.0 is available. Install it now?\n\n"
		+ "It downloads from the toolkit's GitHub releases and installs when you close or "
		+ "restart the editor. The new files show up in version control; commit them so "
		+ "everyone on the project runs the same version.")


static func run(testing) -> void:
	_test_text(testing)


static func _test_text(testing) -> void:
	testing.begin("Update prompt: the window's text")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray()), _TEXT, "no changed files → the version and what installing does")
	testing.eq(UpdatePrompt.text_for("1.2.0", PackedStringArray(["core/a.gd"])), _TEXT
			+ "\n\n1 toolkit files were changed in this project, and installing replaces them. "
			+ "A copy is kept until the new version starts:\n  core/a.gd",
			"one changed file → named")
	var nine := PackedStringArray()
	for index: int in 9:
		nine.append("f%d.gd" % index)
	var listed := UpdatePrompt.text_for("1.2.0", nine).split("\n")
	testing.eq(listed[listed.size() - 2], "  f7.gd", "the eighth changed file → the last named")
	testing.eq(listed[listed.size() - 1], "  …", "a ninth → an ellipsis instead")
	print("")
