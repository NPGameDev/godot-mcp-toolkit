@tool
extends RefCounted
## Fixture builders the self-update tests share: a signing key made once per run,
## release zips written with ZIPPacker, signed manifests, installed addon folders,
## staged updates, installer scenarios and a loopback server for the release's
## downloads, all under scratch folders named with the process id.

const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const UpdateInstaller := preload("res://addons/godot_mcp_toolkit/self_update/update_installer.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/self_update/install_mode.gd")
const EditorRestartProbe := preload("res://addons/godot_mcp_toolkit/self_update/editor_restart_probe.gd")
const RecoveryFiles := preload("res://addons/godot_mcp_toolkit/self_update/recovery_files.gd")

## Where the installer reads the host that stands in for GitHub.
const HOST_ENV := "GODOT_MCP_UPDATE_CHECK_HOST"

## The journal the 1.2.0 toolkit writes. 1.2.0's code stays on users' machines and writes
## this for a later release to read, so this text never changes: if a test against it
## fails, the change that broke it needs a bridge release.
const PINNED_1_2_0_JOURNAL := """{
	"attempts": 2,
	"backup": "backup-1.1.0",
	"changed_files": [
		"core/a.gd"
	],
	"compatible_server": "1.1.0",
	"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"format": 1,
	"from": "1.1.0",
	"reason": "a held file",
	"state": "staged",
	"to": "1.2.0"
}"""

## The journal the 1.2.0 applier leaves when an exit ends between its two renames: the
## state and its Unix time. The recovery plugin reads it with its own code, so this text
## never changes either.
const PINNED_1_2_0_APPLYING_JOURNAL := """{
	"applying_at": 1794300000,
	"attempts": 1,
	"backup": "backup-1.1.0",
	"changed_files": [
		"core/a.gd"
	],
	"compatible_server": "1.1.0",
	"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"format": 1,
	"from": "1.1.0",
	"reason": "",
	"state": "applying",
	"to": "1.2.0"
}"""

## The journal the 1.2.0 applier leaves when both renames ran: the applying time stays.
## The recovery plugin reads it with its own code, so this text never changes either.
const PINNED_1_2_0_APPLIED_JOURNAL := """{
	"applying_at": 1794300000,
	"attempts": 1,
	"backup": "backup-1.1.0",
	"changed_files": [
		"core/a.gd"
	],
	"compatible_server": "1.1.0",
	"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"format": 1,
	"from": "1.1.0",
	"reason": "",
	"state": "applied",
	"to": "1.2.0"
}"""

## The journal a restore leaves after the new version did not load: not applied, with the
## mark of the restore. Both readers must agree on it, so this text never changes either.
const PINNED_1_2_0_RESTORED_JOURNAL := """{
	"applying_at": 1794300000,
	"attempts": 1,
	"backup": "backup-1.1.0",
	"changed_files": [
		"core/a.gd"
	],
	"compatible_server": "1.1.0",
	"expected_tree_hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"format": 1,
	"from": "1.1.0",
	"reason": "version 1.2.0 did not load in Godot 4.5",
	"restored": true,
	"state": "not_applied",
	"to": "1.2.0"
}"""

## The saved entries of the toolkit and of the recovery plugin, as the editor lists them.
const TOOLKIT_PLUGIN_ENTRY := "res://addons/godot_mcp_toolkit/plugin.cfg"
const RECOVERY_PLUGIN_ENTRY := "res://addons/.godot_mcp_toolkit_recovery/plugin.cfg"

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
## directory entries a release zip carries, each once, then [param repeated]: an empty
## entry per name, for a name the zip already holds.[br]
## [br]
## From 4.7 [method ZIPPacker.start_file] also writes the entry of the folder a name sits in
## when that folder has none yet, which for a folder's own name writes it twice, so the two
## directory entries go through [code]add_directory[/code] there. A zip whose files sit in
## the addon folder itself then holds the same entries on every version.
static func write_zip(path: String, entries: Dictionary, repeated: PackedStringArray = PackedStringArray()) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var packer := ZIPPacker.new()
	packer.open(path)
	for directory: String in ["addons/", "addons/godot_mcp_toolkit/"]:
		if packer.has_method("add_directory"):
			packer.call("add_directory", directory)
		else:
			packer.start_file(directory)
			packer.close_file()
	for entry: String in entries:
		packer.start_file(entry)
		packer.write_file(str(entries[entry]).to_utf8_buffer())
		packer.close_file()
	for entry: String in repeated:
		packer.start_file(entry)
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


## A scratch addon at [param installed_version] holding [param installed_files], and the
## scenario around it: the addon and update folders, their absolute forms, a project file
## whose saved plugins hold the recovery plugin, and the options that point an apply or a
## settle at them. The update folder is not created here.
static func make_scenario(purpose: String, installed_version: String, installed_files: Dictionary) -> Dictionary:
	var addon := scratch(purpose + "_addon")
	var updates := scratch(purpose + "_updates")
	var project := scratch(purpose + "_project")
	make_addon(addon, installed_version, installed_files)
	var project_file := project.path_join("project.godot")
	write_project_file(project_file, PackedStringArray([TOOLKIT_PLUGIN_ENTRY, RECOVERY_PLUGIN_ENTRY]))
	return {
		"addon": addon,
		"updates": updates,
		"project": project,
		"addon_path": ProjectSettings.globalize_path(addon),
		"updates_path": ProjectSettings.globalize_path(updates),
		"options": {
			"addon_folder": addon,
			"update_folder": updates,
			"project_file": project_file,
			"engine_version": "4.7",
			"public_keys": [public_pem(key())],
			"guard_facts": {},
		},
	}


## Writes a project file at [param path] whose saved plugins are [param enabled], as the
## editor saves them.
static func write_project_file(path: String, enabled: PackedStringArray) -> void:
	var quoted := PackedStringArray()
	for entry: String in enabled:
		quoted.append("\"%s\"" % entry)
	var text := "config_version=5\n\n[editor_plugins]\n\nenabled=PackedStringArray(%s)\n" % ", ".join(quoted)
	FolderFiles.write_checked(ProjectSettings.globalize_path(path), text.to_utf8_buffer())


## Whether the folder [param relative] exists in the update folder of [param scenario].
static func scenario_has_folder(scenario: Dictionary, relative: String) -> bool:
	return DirAccess.dir_exists_absolute(str(scenario["updates_path"]).path_join(relative))


## Deletes the addon, update and project folders of [param scenario].
static func remove_scenario(scenario: Dictionary) -> void:
	remove(str(scenario["addon"]))
	remove(str(scenario["updates"]))
	remove(str(scenario["project"]))


## The manifest text for a zip of [param archive_bytes] at [param version]. It names a
## recommended server only when [param compatible_server] is set, as the key is optional.
static func manifest_text(
		version: String, archive_bytes: PackedByteArray, min_godot: String = "4.2",
		compatible_server: String = "") -> String:
	var manifest := {
		"format": 1,
		"version": version,
		"archive": ReleaseAssets.archive_name(version),
		"archive_size": archive_bytes.size(),
		"archive_sha256": ContentHash.of_bytes(archive_bytes),
		"min_godot": min_godot,
	}
	if not compatible_server.is_empty():
		manifest["compatible_server"] = compatible_server
	return JSON.stringify(manifest)


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
## as the stepper's caller would: the zip, its manifest signed by [param signing_key], the
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


## Keeps a verified release of [param version] in [param update_folder] as the installer
## does while it waits for the user: the manifest and its signature by [param signing_key],
## with no journal, zip or stage. Returns the zip's bytes, for a test that serves them.
## The manifest names [param compatible_server] when it is set.
static func keep_verified(
		update_folder: String, version: String, files: Dictionary, signing_key: CryptoKey,
		min_godot: String = "4.2", compatible_server: String = "") -> PackedByteArray:
	var assets := release_assets(version, files, signing_key, min_godot, compatible_server)
	var absolute := ProjectSettings.globalize_path(UpdateFolder.version_folder(version, update_folder))
	for asset_name: String in [ReleaseAssets.manifest_name(version), ReleaseAssets.signature_name(version)]:
		FolderFiles.write_checked(absolute.path_join(asset_name), assets[asset_name])
	return assets[ReleaseAssets.archive_name(version)]


## Whether the update folder of [param world] holds [param file_name] of [param version].
static func has_release_file(world: Dictionary, version: String, file_name: String) -> bool:
	return FileAccess.file_exists(UpdateFolder.version_folder(version, str(world["updates"])).path_join(file_name))


## Edits the installed file [param path] of [param world], so it differs from the addon's
## release file list.
static func edit_installed_file(world: Dictionary, path: String) -> void:
	FolderFiles.write_checked(ProjectSettings.globalize_path(str(world["addon"])).path_join(path),
			"edited by hand".to_utf8_buffer())


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


## Makes the file [param path] read-only, or writable again when [param read_only] is
## false: the read-only attribute on Windows, the owner's write bit elsewhere.
static func set_read_only(path: String, read_only: bool) -> void:
	if OS.get_name() == "Windows":
		FileAccess.set_read_only_attribute(path, read_only)
		return
	var permissions := FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_READ_GROUP | FileAccess.UNIX_READ_OTHER
	if not read_only:
		permissions |= FileAccess.UNIX_WRITE_OWNER
	FileAccess.set_unix_permissions(path, permissions)


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


## One installer scenario's world: the update check runner's cache naming
## [param latest], consent given, the install mode [param mode], a scratch addon at
## [param installed], a scratch update folder, a scratch project file whose saved plugins
## hold the recovery plugin, a [RecoveryStandIn] for the recovery plugin's files, and the
## installer's options. The runner's cache path is fixed, so its file is saved here and put
## back by [method end_world].
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
	var project := scratch(purpose + "_project")
	make_addon(addon, installed, {"core/a.gd": "a"})
	var project_file := project.path_join("project.godot")
	write_project_file(project_file, PackedStringArray([TOOLKIT_PLUGIN_ENTRY, RECOVERY_PLUGIN_ENTRY]))
	# Loaded, not preloaded: trust_fixtures.gd preloads this file.
	var trust_fixtures: GDScript = load("res://test/units/trust_fixtures.gd")
	var trust_document: String = trust_fixtures.call("first_document", [key()])
	var recovery := RecoveryStandIn.new()
	recovery.update_folder = updates
	return {
		"cache_path": cache_path,
		"saved_cache": saved_cache,
		"addon": addon,
		"updates": updates,
		"project": project,
		"options": {
			"addon_folder": addon,
			"update_folder": updates,
			"project_file": project_file,
			"trust_document": trust_document,
			"trust_store": scratch(purpose + "_trust"),
			"guard_facts": {"toolkit_repository": false},
			"project_settings": ModeSettings.new(mode),
			"recovery": recovery,
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
	remove(str(world["project"]))
	remove(str((world["options"] as Dictionary)["trust_store"]))
	var cache_path: String = world["cache_path"]
	if world["saved_cache"] == null:
		DirAccess.remove_absolute(cache_path)
	else:
		var file := FileAccess.open(cache_path, FileAccess.WRITE)
		file.store_buffer(world["saved_cache"])
		file.close()


## Points [constant HOST_ENV] at [param host], so the installer's and the downloader's
## fetches go there instead of GitHub. Returns the value it held, for [method restore_host].
static func set_host(host: String) -> String:
	var previous := OS.get_environment(HOST_ENV)
	OS.set_environment(HOST_ENV, host)
	return previous


## Puts [constant HOST_ENV] back to [param previous], the value [method set_host] returned;
## an empty one unsets it, as it was before.
static func restore_host(previous: String) -> void:
	if previous.is_empty():
		OS.unset_environment(HOST_ENV)
	else:
		OS.set_environment(HOST_ENV, previous)


## The files a GitHub release of [param version] serves to the installer: its zip
## holding [param files], the manifest, and the manifest's signature by
## [param signing_key]; asset name to bytes, for [LoopbackReleaseServer]. The manifest
## names [param compatible_server] when it is set.
static func release_assets(
		version: String, files: Dictionary, signing_key: CryptoKey, min_godot: String = "4.2",
		compatible_server: String = "") -> Dictionary:
	var zip_path := scratch("release_assets_%s.zip" % version)
	write_zip(zip_path, release_entries(version, files))
	var archive_bytes := FileAccess.get_file_as_bytes(zip_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(zip_path))
	var manifest := manifest_text(version, archive_bytes, min_godot, compatible_server).to_utf8_buffer()
	return {
		ReleaseAssets.archive_name(version): archive_bytes,
		ReleaseAssets.manifest_name(version): manifest,
		ReleaseAssets.signature_name(version): signature_of(manifest, signing_key),
	}


## A stand-in for [ProjectSettings] that holds only the install mode.
class ModeSettings extends RefCounted:
	var _mode: String

	func _init(mode: String) -> void:
		_mode = mode

	## Changes the mode, as the user does in the project settings.
	func set_mode(mode: String) -> void:
		_mode = mode

	func has_setting(key: String) -> bool:
		return key == InstallMode.SETTING

	func get_setting(key: String) -> Variant:
		return _mode if key == InstallMode.SETTING else null


## A stand-in for the editor the restart gate asks: it reports what a case sets and counts
## the restarts it is asked for. It starts as a windowed 4.5 editor with nothing unsaved.
class RestartProbeStandIn extends EditorRestartProbe:
	var unsaved_scripts := PackedStringArray()
	var running_game: bool = false
	var untitled_scenes: int = 0
	var version: String = "4.5"
	var scanning: bool = false
	var restarts: int = 0

	func findings() -> Dictionary:
		return {
			UNSAVED_SCRIPTS: unsaved_scripts,
			RUNNING_GAME: running_game,
			UNTITLED_SCENES: untitled_scenes,
		}

	func engine_version() -> String:
		return version

	func can_restart() -> bool:
		return true

	func is_scanning() -> bool:
		return scanning

	func restart() -> void:
		restarts += 1


## A stand-in for the recovery plugin's files, so a case writes no plugin and saves no
## project file. It counts the installs and removes it is asked for and keeps the state
## the journal in [member update_folder] held at each install; each install returns
## [member failure], and [member in_place] is what [method is_in_place] reports.
class RecoveryStandIn extends RecoveryFiles:
	var update_folder: String = ""
	var failure: String = ""
	var in_place: bool = true
	var installs: int = 0
	var removes: int = 0
	var journal_states := PackedStringArray()

	func install() -> String:
		installs += 1
		journal_states.append(str(UpdateJournal.read(update_folder)["state"]))
		return failure

	func remove() -> void:
		removes += 1

	func is_in_place() -> bool:
		return in_place


## A loopback HTTP server standing in for GitHub's release downloads, for the
## installer cases that verify or download during the session. It answers each GET
## with the asset whose name ends the request path, or 404, and closes the
## connection. It serves only while [method poll] runs, once per frame; point
## GODOT_MCP_UPDATE_CHECK_HOST at [method host].
class LoopbackReleaseServer extends RefCounted:
	var _server := TCPServer.new()
	var _assets := {}
	var _redirects := {}
	var _peers: Array[StreamPeerTCP] = []
	var _requests: Array[String] = []
	var _connections := 0
	var _paths: Array[String] = []
	var _held_path_ends: Array[String] = []
	var _held_peers: Array[StreamPeerTCP] = []
	var _breaks_handshakes := false

	func _init(assets: Dictionary) -> void:
		_assets = assets
		# A case whose listener never opened would read its zero requests as a pass.
		var error := _server.listen(0, "127.0.0.1")
		if error != OK:
			push_error("The loopback release server could not listen (error %d)." % error)

	## The base URL to put in [constant HOST_ENV].
	func host() -> String:
		return "http://127.0.0.1:%d" % _server.get_local_port()

	## How many connections [method poll] has taken so far. The server closes each after
	## one answer, so this also counts the requests.
	func connections() -> int:
		return _connections

	## Answers a request whose path ends in [param path_end] with [param status] pointing at
	## [param location], before any asset; an empty location sends no Location header. The
	## reply has a small body, as a real redirect does.
	func redirect(path_end: String, status: int, location: String) -> void:
		_redirects[path_end] = {"status": status, "location": location}

	## The path of each request answered or held so far, in the order they arrived.
	func paths() -> Array[String]:
		return _paths.duplicate()

	## Leaves a request whose path ends in [param path_end] unanswered, so the client's
	## timeout ends it.
	func hold(path_end: String) -> void:
		_held_path_ends.append(path_end)

	## Answers whatever arrives with bytes that are no TLS record, which is what a TLS client
	## meets at a plain listener. It takes what the client sent and stays connected: a hang-up
	## with those bytes unread reaches the engine as a failure to connect, not as a failed
	## handshake.
	func break_handshakes() -> void:
		_breaks_handshakes = true

	## Takes the connections waiting and answers each request whose headers have all
	## arrived. A case calls it once per frame; between calls nothing is answered.
	func poll() -> void:
		while _server.is_connection_available():
			_peers.append(_server.take_connection())
			_requests.append("")
			_connections += 1
		for index: int in range(_peers.size() - 1, -1, -1):
			var peer: StreamPeerTCP = _peers[index]
			peer.poll()
			if _breaks_handshakes:
				if peer.get_available_bytes() > 0:
					peer.get_data(peer.get_available_bytes())
					peer.put_data("plain text".to_utf8_buffer())
				continue
			_requests[index] += peer.get_utf8_string(peer.get_available_bytes())
			if not _requests[index].contains("\r\n\r\n"):
				continue
			var path := _requests[index].get_slice(" ", 1)
			_paths.append(path)
			if _is_held(path):
				_held_peers.append(peer)
			else:
				_answer(peer, path)
				peer.disconnect_from_host()
			_peers.remove_at(index)
			_requests.remove_at(index)

	## Hangs up on every connection, held ones included, and closes the listener.
	func stop() -> void:
		for peer: StreamPeerTCP in _peers:
			peer.disconnect_from_host()
		for peer: StreamPeerTCP in _held_peers:
			peer.disconnect_from_host()
		_peers.clear()
		_held_peers.clear()
		_requests.clear()
		_server.stop()

	func _is_held(path: String) -> bool:
		for path_end: String in _held_path_ends:
			if path.ends_with(path_end):
				return true
		return false

	func _answer(peer: StreamPeerTCP, path: String) -> void:
		for path_end: String in _redirects:
			if path.ends_with(path_end):
				var hop: Dictionary = _redirects[path_end]
				var location := str(hop["location"])
				var location_header := "" if location.is_empty() else "Location: %s\r\n" % location
				peer.put_data(("HTTP/1.1 %d Moved\r\n%sContent-Length: 5\r\nConnection: close\r\n\r\nmoved"
						% [int(hop["status"]), location_header]).to_utf8_buffer())
				return
		for asset_name: String in _assets:
			if path.ends_with("/" + asset_name):
				var body: PackedByteArray = _assets[asset_name]
				peer.put_data(("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()).to_utf8_buffer())
				peer.put_data(body)
				return
		peer.put_data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_utf8_buffer())
