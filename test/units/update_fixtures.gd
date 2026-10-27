@tool
extends RefCounted
## Fixture builders the self-update tests share: a signing key made once per run,
## release zips written with ZIPPacker, signed manifests, installed addon folders,
## staged updates, installer scenarios and a loopback server for the release's
## downloads, all under scratch folders named with the process id.

const ContentHash := preload("res://addons/godot_mcp_toolkit/update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/update/release_file_list.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/update/install_mode.gd")

## A stand-in for [ProjectSettings] that holds only the install mode.
class ModeSettings extends RefCounted:
	var _mode: String

	func _init(mode: String) -> void:
		_mode = mode

	func has_setting(key: String) -> bool:
		return key == InstallMode.SETTING

	func get_setting(key: String) -> Variant:
		return _mode if key == InstallMode.SETTING else null


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


## Stages a release of [param version] holding [param files] in [param update_folder]
## as the installer would: the zip, its manifest signed by [param signing_key], and a
## record in [param state] over [param from_version].
static func stage(
		update_folder: String, version: String, files: Dictionary, from_version: String,
		signing_key: CryptoKey, state: String = PendingUpdate.STAGED, min_godot: String = "4.2") -> void:
	var folder := PendingUpdate.version_folder(version, update_folder)
	var archive := folder.path_join(ReleaseAssets.archive_name(version))
	write_zip(archive, release_entries(version, files))
	var archive_bytes := FileAccess.get_file_as_bytes(archive)
	var manifest := manifest_text(version, archive_bytes, min_godot).to_utf8_buffer()
	var absolute := ProjectSettings.globalize_path(folder)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.manifest_name(version)), manifest)
	FolderFiles.write_checked(absolute.path_join(ReleaseAssets.signature_name(version)), signature_of(manifest, signing_key))
	PendingUpdate.write({"state": state, "version": version, "from_version": from_version,
			"compatible_server": "1.1.0"}, update_folder)


## [method stage], then one byte appended to the staged zip, so it no longer matches
## its signed manifest.
static func stage_tampered(
		update_folder: String, version: String, files: Dictionary, from_version: String,
		signing_key: CryptoKey) -> void:
	stage(update_folder, version, files, from_version, signing_key)
	var archive := ProjectSettings.globalize_path(PendingUpdate.version_folder(version, update_folder)).path_join(
			ReleaseAssets.archive_name(version))
	var file := FileAccess.open(archive, FileAccess.READ_WRITE)
	file.seek_end()
	file.store_8(0)
	file.close()


## One installer scenario's world: the update check runner's cache naming
## [param latest], consent given, the install mode [param mode], a scratch addon at
## [param installed], a scratch update folder, and the installer's options. The
## runner's cache path is fixed, so its file is saved here and put back by
## [method end_world].
static func begin_world(purpose: String, latest: String, mode: String, installed: String) -> Dictionary:
	var cache_path := ProjectSettings.globalize_path(UpdateCheckRunner.STATE_PATH)
	var saved_cache: Variant = FileAccess.get_file_as_bytes(cache_path) if FileAccess.file_exists(cache_path) else null
	DirAccess.make_dir_recursive_absolute(cache_path.get_base_dir())
	var cache := FileAccess.open(cache_path, FileAccess.WRITE)
	# A check made now is not due, so the runner sends nothing.
	cache.store_string(JSON.stringify({"last_check": int(Time.get_unix_time_from_system()),
			"latest_version": latest, "store_listed": false, "dismissed_version": ""}))
	cache.close()
	Consent.set_readers(func() -> bool: return true, func(_step_id: StringName) -> bool: return true)
	var addon := scratch(purpose + "_addon")
	var updates := scratch(purpose + "_updates")
	make_addon(addon, installed, {"core/a.gd": "a"})
	return {
		"cache_path": cache_path,
		"saved_cache": saved_cache,
		"addon": addon,
		"updates": updates,
		"options": {
			"addon_folder": addon,
			"update_folder": updates,
			"public_keys": [public_pem(key())],
			"guard_facts": {"toolkit_repository": false},
			"project_settings": ModeSettings.new(mode),
		},
	}


## A runner and an installer for [param world]; the installer joins [param tree]'s root.
static func start_world(world: Dictionary, tree: SceneTree) -> Dictionary:
	var runner := UpdateCheckRunner.new()
	var installer := UpdateInstaller.new(runner, world["options"])
	tree.root.add_child(installer)
	return {"runner": runner, "installer": installer}


## Frees what [method start_world] made, resets consent, deletes the scratch folders
## and puts the runner's cache back.
static func end_world(world: Dictionary, nodes: Dictionary) -> void:
	(nodes["installer"] as Node).free()
	(nodes["runner"] as Node).free()
	Consent.reset_readers()
	remove(str(world["addon"]))
	remove(str(world["updates"]))
	var cache_path: String = world["cache_path"]
	if world["saved_cache"] == null:
		DirAccess.remove_absolute(cache_path)
	else:
		var file := FileAccess.open(cache_path, FileAccess.WRITE)
		file.store_buffer(world["saved_cache"])
		file.close()


## The files a GitHub release of [param version] serves to the installer: its zip
## holding [param files], the manifest, and the manifest's signature by
## [param signing_key]; asset name to bytes, for [LoopbackReleaseServer].
static func release_assets(version: String, files: Dictionary, signing_key: CryptoKey) -> Dictionary:
	var zip_path := scratch("release_assets_%s.zip" % version)
	write_zip(zip_path, release_entries(version, files))
	var archive_bytes := FileAccess.get_file_as_bytes(zip_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(zip_path))
	var manifest := manifest_text(version, archive_bytes).to_utf8_buffer()
	return {
		ReleaseAssets.archive_name(version): archive_bytes,
		ReleaseAssets.manifest_name(version): manifest,
		ReleaseAssets.signature_name(version): signature_of(manifest, signing_key),
	}


## A loopback HTTP server standing in for GitHub's release downloads, for the
## installer cases that verify or download during the session. It answers each GET
## with the asset whose name ends the request path, or 404, and closes the
## connection. It serves only while [method poll] runs, once per frame; point
## GODOT_MCP_UPDATE_CHECK_HOST at [method host].
class LoopbackReleaseServer extends RefCounted:
	var _server := TCPServer.new()
	var _assets := {}
	var _peers: Array[StreamPeerTCP] = []
	var _requests: Array[String] = []

	func _init(assets: Dictionary) -> void:
		_assets = assets
		_server.listen(0, "127.0.0.1")

	func host() -> String:
		return "http://127.0.0.1:%d" % _server.get_local_port()

	func poll() -> void:
		while _server.is_connection_available():
			_peers.append(_server.take_connection())
			_requests.append("")
		for index in range(_peers.size() - 1, -1, -1):
			var peer := _peers[index]
			peer.poll()
			_requests[index] += peer.get_utf8_string(peer.get_available_bytes())
			if not _requests[index].contains("\r\n\r\n"):
				continue
			_answer(peer, _requests[index].get_slice(" ", 1))
			peer.disconnect_from_host()
			_peers.remove_at(index)
			_requests.remove_at(index)

	func stop() -> void:
		for peer in _peers:
			peer.disconnect_from_host()
		_peers.clear()
		_requests.clear()
		_server.stop()

	func _answer(peer: StreamPeerTCP, path: String) -> void:
		for asset_name: String in _assets:
			if path.ends_with("/" + asset_name):
				var body: PackedByteArray = _assets[asset_name]
				peer.put_data(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()).to_utf8_buffer())
				peer.put_data(body)
				return
		peer.put_data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_utf8_buffer())
