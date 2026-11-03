@tool
extends RefCounted
## Unit tests for the folder helpers: hashing a file, listing hidden and nested files and
## hashing them, a checked write and a write that cannot happen, deleting a tree, and
## deleting a tree that holds a link.

const Testing := preload("res://test/units/testing.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

const _ABC_SHA256 := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
const _AWKWARD_NAMES := ["with space", "café 日本語"]
const _ENV_SYSTEM_ROOT := "SystemRoot"


static func run(testing: Testing) -> void:
	_test_file_hash(testing)
	_test_list_and_hash(testing)
	_test_write_checked(testing)
	_test_remove(testing)
	_test_remove_link_at_the_top(testing)
	_test_remove_link_nested(testing)
	_test_is_link(testing)
	_test_is_link_awkward_names(testing)
	_test_is_link_fails_closed(testing)
	_test_is_link_without_system_root(testing)
	_test_shell_never_runs_a_name(testing)


static func _test_file_hash(testing: Testing) -> void:
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


static func _test_list_and_hash(testing: Testing) -> void:
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


static func _test_write_checked(testing: Testing) -> void:
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


static func _test_remove(testing: Testing) -> void:
	testing.begin("Folder files: deleting a tree")
	var target := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_target"))
	FolderFiles.write_checked(target.path_join("a.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(target.path_join("sub/b.txt"), "abc".to_utf8_buffer())
	var removed := FolderFiles.remove_tree(target)
	var gone := not DirAccess.dir_exists_absolute(target)
	testing.ok(removed and gone, "remove_tree → the folder is gone")
	testing.ok(FolderFiles.remove_tree(target), "removing a missing folder → done")
	print("")


# The engine removes a link as a link everywhere but on Godot 4.2 on Unix, where its
# remove calls rmdir, which fails on a symlink.
static func _engine_keeps_links() -> bool:
	return OS.get_name() != "Windows" and not DirAccess.open("user://").has_method("is_link")


# Godot 4.2 on Windows shows no link, so the check there runs fsutil.
static func _asks_fsutil() -> bool:
	return OS.get_name() == "Windows" and not DirAccess.open("user://").has_method("is_link")


# A link and the folder it points at, with a file in the target.
static func _make_link(purpose: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch(purpose))
	var target := root.path_join("target")
	var holder := root.path_join("holder")
	FolderFiles.write_checked(target.path_join("kept.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(target.path_join("sub/kept.txt"), "abc".to_utf8_buffer())
	FolderFiles.write_checked(holder.path_join("mine.txt"), "abc".to_utf8_buffer())
	var link := holder.path_join("link")
	return {"root": root, "target": target, "holder": holder, "link": link,
			"made": UpdateFixtures.make_folder_link(link, target)}


# Deletes what _make_link made. A link left behind goes first, so that the walk through
# the root cannot reach the target through it twice.
static func _remove_link(link_files: Dictionary) -> void:
	FolderFiles.remove_tree(str(link_files["link"]))
	FolderFiles.remove_tree(str(link_files["root"]))


static func _test_remove_link_at_the_top(testing: Testing) -> void:
	testing.begin("Folder files: deleting a folder that is a link")
	var made := _make_link("folder_link_top")
	if not made["made"]:
		print("  SKIP: no folder link can be made here")
		FolderFiles.remove_tree(str(made["root"]))
		print("")
		return
	var removed := FolderFiles.remove_tree(str(made["link"]))
	var kept := FolderFiles.list(str(made["target"]))
	var link_gone := not DirAccess.dir_exists_absolute(str(made["link"]))
	_remove_link(made)
	testing.eq(kept, PackedStringArray(["kept.txt", "sub/kept.txt"]), "the target's files → all still there")
	testing.eq(removed, not _engine_keeps_links(), "the result → whether the link went")
	testing.eq(link_gone, removed, "and it says so truly")
	print("")


static func _test_remove_link_nested(testing: Testing) -> void:
	testing.begin("Folder files: deleting a tree with a link inside")
	var made := _make_link("folder_link_nested")
	if not made["made"]:
		print("  SKIP: no folder link can be made here")
		FolderFiles.remove_tree(str(made["root"]))
		print("")
		return
	var removed := FolderFiles.remove_tree(str(made["holder"]))
	var kept := FolderFiles.list(str(made["target"]))
	var holder_gone := not DirAccess.dir_exists_absolute(str(made["holder"]))
	_remove_link(made)
	testing.eq(kept, PackedStringArray(["kept.txt", "sub/kept.txt"]), "the target's files → all still there")
	testing.eq(removed, not _engine_keeps_links(), "the result → whether the tree went")
	testing.eq(holder_gone, removed, "and it says so truly")
	print("")


# Every supported version sees a link: the engine from 4.3, a process on 4.2.
static func _test_is_link(testing: Testing) -> void:
	testing.begin("Folder files: telling a link from a folder")
	var made := _make_link("folder_is_link")
	var link_seen := FolderFiles.is_link(str(made["link"]))
	var folder_seen := FolderFiles.is_link(str(made["target"]))
	var made_link: bool = made["made"]
	_remove_link(made)
	testing.ok(not folder_seen, "a real folder → not a link")
	if made_link:
		testing.ok(link_seen, "a link → always seen")
	else:
		print("  SKIP: no folder link can be made here")
	print("")


# On 4.2 the path reaches the check through a process, whose quoting and encoding must not
# change the answer.
static func _test_is_link_awkward_names(testing: Testing) -> void:
	testing.begin("Folder files: telling a link from a folder under awkward names")
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_link_names"))
	var real_seen := {}
	var link_seen := {}
	var made_links := {}
	var links := PackedStringArray()
	for folder_name: String in _AWKWARD_NAMES:
		var real := root.path_join(folder_name)
		var link := root.path_join("links").path_join(folder_name)
		FolderFiles.write_checked(real.path_join("kept.txt"), "abc".to_utf8_buffer())
		DirAccess.make_dir_recursive_absolute(link.get_base_dir())
		made_links[folder_name] = UpdateFixtures.make_folder_link(link, real)
		real_seen[folder_name] = FolderFiles.is_link(real)
		link_seen[folder_name] = FolderFiles.is_link(link)
		links.append(link)
	for link: String in links:
		FolderFiles.remove_tree(link)
	FolderFiles.remove_tree(root)
	for folder_name: String in _AWKWARD_NAMES:
		testing.ok(not bool(real_seen[folder_name]), "a real folder named \"%s\" → not a link" % folder_name)
		if bool(made_links[folder_name]):
			testing.ok(bool(link_seen[folder_name]), "a link named \"%s\" → seen" % folder_name)
		else:
			print("  SKIP: no folder link named \"%s\" can be made here" % folder_name)
	print("")


# 4.2 on Windows asks fsutil and counts anything but its "not a reparse point" as a link. A
# path that is not there is the answer the test can produce: fsutil says something else.
static func _test_is_link_fails_closed(testing: Testing) -> void:
	testing.begin("Folder files: an answer that is not a clear no")
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_link_closed"))
	DirAccess.make_dir_recursive_absolute(root)
	var seen := FolderFiles.is_link(root.path_join("not_here"))
	FolderFiles.remove_tree(root)
	testing.eq(seen, _asks_fsutil(), "a missing folder → a link only where fsutil answers for it")
	print("")


# fsutil goes by its full path from SystemRoot, since a bare name would search the project
# before System32. With no SystemRoot there is no path to name, so a real folder reads as a
# link. The second row shows that the variable made the difference.
static func _test_is_link_without_system_root(testing: Testing) -> void:
	testing.begin("Folder files: no SystemRoot to find fsutil from")
	if not _asks_fsutil():
		print("  SKIP: only Godot 4.2 on Windows asks fsutil")
		print("")
		return
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_link_no_root"))
	DirAccess.make_dir_recursive_absolute(root)
	var system_root := OS.get_environment(_ENV_SYSTEM_ROOT)
	OS.set_environment(_ENV_SYSTEM_ROOT, "")
	var seen_without := FolderFiles.is_link(root)
	OS.set_environment(_ENV_SYSTEM_ROOT, system_root)
	var seen_with := FolderFiles.is_link(root)
	FolderFiles.remove_tree(root)
	testing.ok(seen_without, "a real folder, SystemRoot empty → a link")
	testing.ok(not seen_with, "a real folder, SystemRoot back → not a link")
	print("")


# On 4.2 on Unix OS.execute runs a shell, so a folder name must never reach it. The name
# would create the marker if it did.
static func _test_shell_never_runs_a_name(testing: Testing) -> void:
	testing.begin("Folder files: a folder name the shell would expand")
	var root := ProjectSettings.globalize_path(UpdateFixtures.scratch("folder_shell"))
	var marker := root.path_join("ran")
	var folder := root.path_join("$(touch ran)")
	FolderFiles.write_checked(folder.path_join("a.txt"), "abc".to_utf8_buffer())
	var seen := FolderFiles.is_link(folder)
	var removed := FolderFiles.remove_tree(folder)
	var marker_made := FileAccess.file_exists(marker) or FileAccess.file_exists("ran")
	var refused := _engine_keeps_links()
	FolderFiles.remove_tree(root)
	testing.ok(not marker_made, "the name → never run")
	testing.eq(seen, refused, "the check → refuses only where it would ask a shell")
	testing.eq(removed, not refused, "the delete → the same")
	print("")
