@tool
extends RefCounted
## Fixture builders the self-update tests share: a signing key made once per run,
## release zips written with ZIPPacker, signed manifests, installed addon folders and
## staged updates, all under scratch folders named with the process id.

const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")

static var _key: CryptoKey = null
static var _other_key: CryptoKey = null


## The run's signing key, made on first use.
static func key() -> CryptoKey:
	if _key == null:
		_key = Crypto.new().generate_rsa(2048)
	return _key


## A second key that signs nothing the tests trust.
static func other_key() -> CryptoKey:
	if _other_key == null:
		_other_key = Crypto.new().generate_rsa(2048)
	return _other_key


## The PEM public key of [param signing_key].
static func public_pem(signing_key: CryptoKey) -> String:
	return signing_key.save_to_string(true)


## An RSA-SHA256 signature over [param bytes] by [param signing_key].
static func signature_of(bytes: PackedByteArray, signing_key: CryptoKey) -> PackedByteArray:
	return Crypto.new().sign(HashingContext.HASH_SHA256, ContentHash.digest(bytes), signing_key)


## A scratch [code]user://[/code] folder for [param purpose], unique to this process.
static func scratch(purpose: String) -> String:
	return "user://update_tests_%d_%s" % [OS.get_process_id(), purpose]


## Deletes [param folder] (a [code]user://[/code] or absolute path) and its content.
static func remove(folder: String) -> void:
	FolderFiles.remove_tree(ProjectSettings.globalize_path(folder))


## The [code]plugin.cfg[/code] text of a toolkit at [param version].
static func plugin_config(version: String) -> String:
	return "[plugin]\n\nname=\"Godot MCP Toolkit\"\nversion=\"%s\"\nscript=\"plugin.gd\"\n" % version


## Writes a zip at [param path] holding [param entries] (zip path to text), with the
## directory entries a release zip carries.
static func write_zip(path: String, entries: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var packer := ZIPPacker.new()
	packer.open(path)
	for directory: String in ["addons/", "addons/godot_mcp_toolkit/"]:
		packer.start_file(directory)
		packer.close_file()
	for entry: String in entries:
		packer.start_file(entry)
		packer.write_file(str(entries[entry]).to_utf8_buffer())
		packer.close_file()
	packer.close()


## The zip entries of a release at [param version] holding [param files] (path in
## the addon folder to text), a plugin.cfg, and the release file list.
static func release_entries(version: String, files: Dictionary) -> Dictionary:
	var addon_files := files.duplicate()
	addon_files["plugin.cfg"] = plugin_config(version)
	var listed := {}
	for path: String in addon_files:
		listed[path] = ContentHash.of_bytes(str(addon_files[path]).to_utf8_buffer())
	addon_files[ReleaseFileList.FILE_NAME] = ReleaseFileList.format(listed)
	var entries := {}
	for path: String in addon_files:
		entries["addons/godot_mcp_toolkit/" + path] = addon_files[path]
	return entries


## Writes an installed addon folder at [param folder] for [param version] holding
## [param files], with its release file list.
static func make_addon(folder: String, version: String, files: Dictionary) -> void:
	var entries := release_entries(version, files)
	for entry: String in entries:
		var path := ProjectSettings.globalize_path(folder).path_join(entry.trim_prefix("addons/godot_mcp_toolkit/"))
		FolderFiles.write_checked(path, str(entries[entry]).to_utf8_buffer())


## The manifest text for a zip of [param archive_bytes] at [param version].
static func manifest_text(version: String, archive_bytes: PackedByteArray, min_godot: String = "4.2") -> String:
	return JSON.stringify({
		"format": 1,
		"version": version,
		"archive": ReleaseAssets.archive_name(version),
		"archive_size": archive_bytes.size(),
		"archive_sha256": ContentHash.of_bytes(archive_bytes),
		"min_godot": min_godot,
	})


## Makes [param link] a link to the folder [param target], both absolute: a junction on
## Windows, which needs no elevation, [code]create_link[/code] where the engine has it, and
## [code]ln -s[/code] elsewhere. Returns whether the link now leads to a folder.
static func make_folder_link(link: String, target: String) -> bool:
	if OS.get_name() == "Windows":
		OS.execute("cmd.exe", ["/c", "mklink", "/J", link.replace("/", "\\"), target.replace("/", "\\")])
		return DirAccess.dir_exists_absolute(link)
	var parent := DirAccess.open(link.get_base_dir())
	if parent != null and parent.has_method("create_link"):
		parent.call("create_link", target, link)
	else:
		OS.execute("ln", ["-s", target, link])
	return DirAccess.dir_exists_absolute(link)


## Stages a release of [param version] holding [param files] in [param update_folder]
## as the installer would: the zip, its manifest signed by [param signing_key], the
## unpacked stage, and a journal in [param state] over [param from_version].
static func stage(
		update_folder: String, version: String, files: Dictionary, from_version: String,
		signing_key: CryptoKey, state: String = UpdateJournal.STAGED, min_godot: String = "4.2") -> void:
	var folder := UpdateFolder.version_folder(version, update_folder)
	var archive := folder.path_join(ReleaseAssets.archive_name(version))
	var entries := release_entries(version, files)
	write_zip(archive, entries)
	var stage_folder := ProjectSettings.globalize_path(UpdateFolder.stage_folder(update_folder))
	for entry: String in entries:
		FolderFiles.write_checked(stage_folder.path_join(entry.trim_prefix("addons/godot_mcp_toolkit/")),
				str(entries[entry]).to_utf8_buffer())
	var archive_bytes := FileAccess.get_file_as_bytes(archive)
	var manifest := manifest_text(version, archive_bytes, min_godot).to_utf8_buffer()
	var absolute := ProjectSettings.globalize_path(folder)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.manifest_name(version)), manifest)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.signature_name(version)), signature_of(manifest, signing_key))
	UpdateJournal.write({"state": state, "to": version, "from": from_version,
			"compatible_server": "1.1.0"}, update_folder)


## Makes the file [param file_name] in [param folder] undeletable, or deletable again when
## [param blocked] is false: a read-only file blocks its delete on Windows, a read-only
## parent folder does elsewhere.
static func block_delete(folder: String, file_name: String, blocked: bool) -> void:
	if OS.get_name() == "Windows":
		FileAccess.set_read_only_attribute(folder.path_join(file_name), blocked)
		return
	var permissions := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_EXECUTE_OWNER
	if not blocked:
		permissions |= FileAccess.UNIX_WRITE_OWNER
	FileAccess.set_unix_permissions(folder, permissions)


## [method stage], then one byte appended to the staged zip, so it no longer matches
## its signed manifest.
static func stage_tampered(
		update_folder: String, version: String, files: Dictionary, from_version: String,
		signing_key: CryptoKey) -> void:
	stage(update_folder, version, files, from_version, signing_key)
	var archive := ProjectSettings.globalize_path(UpdateFolder.version_folder(version, update_folder)).path_join(
			ReleaseAssets.archive_name(version))
	var file := FileAccess.open(archive, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_8(0)
	file.close()
