@tool
extends RefCounted
## Unit tests for the update folder: its path and layout, the ignore files written and
## re-written, deleting the backups, and the install log.

const Testing := preload("res://test/units/testing.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")


static func run(testing: Testing) -> void:
	_test_layout(testing)
	_test_ignore_files_written(testing)
	_test_ignore_files_repaired(testing)
	_test_ignore_file_that_cannot_be_written(testing)
	_test_remove_backups(testing)
	_test_remove_backups_that_cannot_go(testing)
	_test_log(testing)


static func _test_layout(testing: Testing) -> void:
	testing.begin("Update folder: where everything lives")
	testing.eq(UpdateFolder.FOLDER, "res://addons/.godot_mcp_toolkit_update", "the folder, in the project, behind a dot")
	testing.eq(UpdateFolder.version_folder("1.2.0"), "res://addons/.godot_mcp_toolkit_update/1.2.0", "a version's folder")
	testing.eq(UpdateFolder.stage_folder(), "res://addons/.godot_mcp_toolkit_update/stage", "the stage")
	testing.eq(UpdateFolder.backup_folder("1.1.0"), "res://addons/.godot_mcp_toolkit_update/backup-1.1.0", "the backup, named for its version")
	testing.ok(UpdateFolder.is_backup_name("backup-1.1.0"), "backup-<from> → a backup")
	testing.ok(not UpdateFolder.is_backup_name("stage"), "the stage → not a backup")
	testing.ok(not UpdateFolder.is_backup_name("1.2.0"), "a version's folder → not a backup")
	print("")


static func _test_ignore_files_written(testing: Testing) -> void:
	testing.begin("Update folder: the ignore files of a new folder")
	var folder := UpdateFixtures.scratch("folder_ignore_new")
	var absolute := ProjectSettings.globalize_path(folder)
	var written := UpdateFolder.ensure_ignore_files(folder)
	var gitignore := FileAccess.get_file_as_string(absolute.path_join(".gitignore"))
	var p4ignore := FileAccess.get_file_as_string(absolute.path_join(".p4ignore"))
	var gdignore_there := FileAccess.file_exists(absolute.path_join(".gdignore"))
	var gdignore := FileAccess.get_file_as_string(absolute.path_join(".gdignore"))
	UpdateFixtures.remove(folder)
	testing.ok(written, "a folder that does not exist yet → created with its ignore files")
	testing.eq(gitignore, "*\n", ".gitignore ignores everything, itself included")
	testing.eq(p4ignore, "*\n", ".p4ignore ignores everything, itself included")
	testing.ok(gdignore_there, ".gdignore exists")
	testing.eq(gdignore, "", ".gdignore is empty")
	print("")


static func _test_ignore_files_repaired(testing: Testing) -> void:
	testing.begin("Update folder: a missing or changed ignore file comes back")
	var folder := UpdateFixtures.scratch("folder_ignore_repair")
	var absolute := ProjectSettings.globalize_path(folder)
	UpdateFolder.ensure_ignore_files(folder)
	DirAccess.remove_absolute(absolute.path_join(".gitignore"))
	FolderFiles.write_checked(absolute.path_join(".p4ignore"), "!keep\n".to_utf8_buffer())
	var repaired := UpdateFolder.ensure_ignore_files(folder)
	var gitignore := FileAccess.get_file_as_string(absolute.path_join(".gitignore"))
	var p4ignore := FileAccess.get_file_as_string(absolute.path_join(".p4ignore"))
	UpdateFixtures.remove(folder)
	testing.ok(repaired, "the repair reports success")
	testing.eq(gitignore, "*\n", "a deleted .gitignore → re-created")
	testing.eq(p4ignore, "*\n", "a changed .p4ignore → written again")
	print("")


static func _test_ignore_file_that_cannot_be_written(testing: Testing) -> void:
	testing.begin("Update folder: an ignore file that cannot be written refuses")
	var folder := UpdateFixtures.scratch("folder_ignore_blocked")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder).path_join(".gitignore"))
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var written := UpdateFolder.ensure_ignore_files(folder)
	Engine.print_error_messages = printed
	UpdateFixtures.remove(folder)
	testing.ok(not written, "a folder where .gitignore goes → false")
	print("")


static func _test_remove_backups(testing: Testing) -> void:
	testing.begin("Update folder: deleting the backups")
	var folder := UpdateFixtures.scratch("folder_backups")
	var absolute := ProjectSettings.globalize_path(folder)
	FolderFiles.write_checked(absolute.path_join("backup-1.0.0/core/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("backup-1.1.0/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("stage/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("1.2.0/a.zip"), "a".to_utf8_buffer())
	var removed := UpdateFolder.remove_backups(folder)
	var left := UpdateFolder.subfolders(folder)
	left.sort()
	var missing_folder_removed := UpdateFolder.remove_backups(folder.path_join("nowhere"))
	var missing_folder_listed := UpdateFolder.subfolders(folder.path_join("nowhere"))
	UpdateFixtures.remove(folder)
	testing.ok(removed, "every backup gone → true")
	testing.eq(left, PackedStringArray(["1.2.0", "stage"]), "only the backups go")
	testing.ok(missing_folder_removed, "a folder that vanished → nothing to delete")
	testing.eq(missing_folder_listed, PackedStringArray(), "a folder that vanished → no subfolders")
	print("")


# A read-only file blocks its delete on Windows; elsewhere a read-only parent folder does.
static func _test_remove_backups_that_cannot_go(testing: Testing) -> void:
	testing.begin("Update folder: a backup that will not go is reported")
	var folder := UpdateFixtures.scratch("folder_backup_held")
	var backup := ProjectSettings.globalize_path(folder).path_join("backup-1.1.0")
	FolderFiles.write_checked(backup.path_join("a.gd"), "a".to_utf8_buffer())
	_block_delete(backup, "a.gd", true)
	var removed := UpdateFolder.remove_backups(folder)
	_block_delete(backup, "a.gd", false)
	UpdateFixtures.remove(folder)
	testing.ok(not removed, "a backup still there → false")
	print("")


static func _test_log(testing: Testing) -> void:
	testing.begin("Update folder: the install log")
	var folder := UpdateFixtures.scratch("folder_log")
	UpdateFolder.log_line("first", folder)
	UpdateFolder.log_line("second", folder)
	var lines := FileAccess.get_file_as_string(UpdateFolder.log_path(folder)).strip_edges().split("\n")
	UpdateFixtures.remove(folder)
	testing.eq(lines.size(), 2, "each call → one line")
	testing.ok(lines[0].ends_with(" first") and lines[1].ends_with(" second"), "appended in order, after a timestamp")
	print("")


static func _block_delete(folder: String, file_name: String, blocked: bool) -> void:
	if OS.get_name() == "Windows":
		FileAccess.set_read_only_attribute(folder.path_join(file_name), blocked)
		return
	var permissions := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_EXECUTE_OWNER
	if not blocked:
		permissions |= FileAccess.UNIX_WRITE_OWNER
	FileAccess.set_unix_permissions(folder, permissions)
