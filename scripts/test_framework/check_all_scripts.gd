# scripts/test_framework/check_all_scripts.gd
# Per-file GDScript validation — loads every .gd file and reports failures.
# Run via: godot --headless --script scripts/test_framework/check_all_scripts.gd
#
# Runs in game mode (no --editor), so scripts that extend editor-only base
# classes are skipped — those are validated by the editor-headless pass in
# validate_gdscript.sh instead.

extends SceneTree

# Editor-only base classes unavailable in game mode. Scripts extending
# these are skipped (editor-headless pass validates them). Update this
# list if the toolkit adds new editor-derived base classes.
const EDITOR_BASE_CLASSES: Array[String] = [
	"EditorPlugin",
	"EditorInspectorPlugin",
	"EditorExportPlugin",
	"EditorProperty",
	"EditorResourcePreviewGenerator",
	"EditorScenePostImport",
	"EditorScript",
	"EditorSyntaxHighlighter",
	"EditorResourcePicker",
	"EditorDebuggerPlugin",
	"EditorNode3DGizmoPlugin",
	"EditorResourceConversionPlugin",
]

const SCAN_ROOT := "res://addons/godot_mcp_toolkit/"

var _pass_count := 0
var _fail_count := 0
var _skip_count := 0


func _init() -> void:
	var files := _glob_gd_files(SCAN_ROOT)
	print("check_all_scripts: scanning %d .gd files under %s" % [files.size(), SCAN_ROOT])
	print("")

	for path in files:
		_check_file(path)

	print("")
	print("check_all_scripts: %d passed, %d failed, %d skipped (editor-only)" % [
		_pass_count, _fail_count, _skip_count,
	])

	if _fail_count > 0:
		print("FAIL: %d script(s) have errors" % _fail_count)
		quit(1)
	else:
		print("PASS: all loadable scripts are valid")
		quit(0)


func _check_file(path: String) -> void:
	var content := FileAccess.get_file_as_string(path)
	if content.is_empty():
		print("  SKIP: %s (empty or unreadable)" % path)
		_skip_count += 1
		return

	if _extends_editor_class(content):
		_skip_count += 1
		return

	var script: Resource = ResourceLoader.load(path)
	if script == null or (script is Script and not script.can_instantiate()):
		print("  FAIL: %s" % path)
		_fail_count += 1
	else:
		_pass_count += 1


func _extends_editor_class(content: String) -> bool:
	for line in content.split("\n", false):
		var stripped := line.strip_edges()

		# Skip blank lines, comments, annotations, and class_name before extends
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if stripped.begins_with("@") or stripped.begins_with("class_name"):
			continue

		if stripped.begins_with("extends "):
			var base_class := stripped.substr(8).strip_edges()
			# Handle inner classes: "EditorPlugin.SomeInner" -> "EditorPlugin"
			# Handle path extends: "res://..." -> not an editor class name
			var base_name := base_class.split(".")[0].split("(")[0].strip_edges()
			return base_name in EDITOR_BASE_CLASSES

		# First real code line that isn't extends — stop looking
		break

	return false


func _glob_gd_files(root: String) -> Array[String]:
	var results: Array[String] = []
	_glob_recursive(root, results)
	results.sort()
	return results


func _glob_recursive(dir_path: String, results: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full_path := dir_path.path_join(entry)
		if dir.current_is_dir():
			_glob_recursive(full_path, results)
		elif entry.ends_with(".gd"):
			results.append(full_path)
		entry = dir.get_next()
	dir.list_dir_end()
