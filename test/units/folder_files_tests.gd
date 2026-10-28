@tool
extends RefCounted
## Unit tests for the folder helpers: hashing a file, listing hidden and nested files and
## hashing them, a checked write and a write that cannot happen, copying a tree, a copy
## that leaves matching files alone, and deleting a tree.

const Testing := preload("res://test/units/testing.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _ABC_SHA256 := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"


static func run(testing) -> void:
	_test_file_hash(testing)
	_test_list_and_hash(testing)
	_test_write_checked(testing)
	_test_copy_and_remove(testing)
	_test_copy_skips_identical(testing)


static func _test_file_hash(testing) -> void:
	testing.begin("Folder files: SHA-256 of a file")
	var folder := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_hash"))
	var path := folder.path_join("abc.txt")
	FolderFiles.write_checked(path, "abc".to_utf8_buffer())
	var digest := FolderFiles.hash_of_file(path)
	var missing := FolderFiles.hash_of_file(path + ".missing")
	FolderFiles.remove_tree(folder)
	testing.eq(digest, _ABC_SHA256, "a file holding \"abc\" → the FIPS 180 vector")
	testing.eq(missing, "", "a missing file → empty")
	print("")


static func _test_list_and_hash(testing) -> void:
	testing.begin("Folder files: listing and hashing")
	var folder := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_list"))
	FolderFiles.write_checked(folder.path_join("b.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(folder.path_join(".hidden"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(folder.path_join("sub/deep/a.txt"), "abc".to_utf8_buffer())
	var listed := FolderFiles.list(folder)
	var hashed := FolderFiles.hashes(folder)
	var missing := FolderFiles.list(folder.path_join("nowhere"))
	FolderFiles.remove_tree(folder)
	testing.eq(listed, PackedStringArray([".hidden", "b.txt", "sub/deep/a.txt"]), "hidden and nested files, relative, sorted")
	testing.eq(hashed.get("sub/deep/a.txt", ""), _ABC_SHA256, "each file → its SHA-256")
	testing.eq(missing, PackedStringArray(), "a missing folder → nothing")
	print("")


static func _test_write_checked(testing) -> void:
	testing.begin("Folder files: a checked write")
	var folder := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_write"))
	var written := FolderFiles.write_checked(folder.path_join("new/dir/a.txt"), "abc".to_utf8_buffer())
	var text := FileAccess.get_file_as_string(folder.path_join("new/dir/a.txt"))
	DirAccess.make_dir_recursive_absolute(folder.path_join("blocked"))
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var over_folder := FolderFiles.write_checked(folder.path_join("blocked"), "abc".to_utf8_buffer())
	Engine.print_error_messages = printed
	FolderFiles.remove_tree(folder)
	testing.ok(written, "a file in folders that do not exist yet → written")
	testing.eq(text, "abc", "and it holds the bytes")
	testing.ok(not over_folder, "a path that is a folder → not written")
	print("")


static func _test_copy_and_remove(testing) -> void:
	testing.begin("Folder files: copying and deleting a tree")
	var source := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_source"))
	var target := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_target"))
	FolderFiles.write_checked(source.path_join("a.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(source.path_join("sub/b.txt"), "abc".to_utf8_buffer())
	var failed := FolderFiles.copy_tree(source, target)
	var copied := FolderFiles.list(target)
	var removed := FolderFiles.remove_tree(target)
	var gone := not DirAccess.dir_exists_absolute(target)
	FolderFiles.remove_tree(source)
	testing.eq(failed, PackedStringArray(), "every file copied")
	testing.eq(copied, PackedStringArray(["a.txt", "sub/b.txt"]), "the target holds the same files")
	testing.ok(removed and gone, "remove_tree → the folder is gone")
	testing.ok(FolderFiles.remove_tree(target), "removing a missing folder → done")
	print("")


# A restore copies the backup over the folder an install changed; a file the install
# never changed already holds the backup's bytes and must not count as a failed write.
# A read-only target file is the injected failure: the headless runner writes in place,
# so writing over it fails.
static func _test_copy_skips_identical(testing: Testing) -> void:
	testing.begin("Folder files: a copy that skips identical files leaves them alone")
	var source := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_skip_source"))
	var target := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_skip_target"))
	FolderFiles.write_checked(source.path_join("same.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(source.path_join("changed.txt"), "new".to_utf8_buffer())
	FolderFiles.write_checked(target.path_join("same.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(target.path_join("changed.txt"), "old".to_utf8_buffer())
	_set_read_only(target.path_join("same.txt"), true)
	var skipping_failed := FolderFiles.copy_tree(source, target, true)
	var changed_text := FileAccess.get_file_as_string(target.path_join("changed.txt"))
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var plain_failed := FolderFiles.copy_tree(source, target)
	Engine.print_error_messages = printed
	_set_read_only(target.path_join("same.txt"), false)
	FolderFiles.remove_tree(source)
	FolderFiles.remove_tree(target)
	testing.eq(skipping_failed, PackedStringArray(), "a matching read-only file → skipped, no failure")
	testing.eq(changed_text, "new", "a differing file → copied")
	testing.eq(plain_failed, PackedStringArray(["same.txt"]),
			"without the skip, the same read-only file → reported as failed")
	print("")


# Makes `path` read-only or writable again: the read-only attribute on Windows,
# the owner's write bit elsewhere.
static func _set_read_only(path: String, read_only: bool) -> void:
	if OS.get_name() == "Windows":
		FileAccess.set_read_only_attribute(path, read_only)
		return
	var permissions := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_READ_OTHER
	if not read_only:
		permissions |= FileAccess.UNIX_WRITE_OWNER
	FileAccess.set_unix_permissions(path, permissions)
