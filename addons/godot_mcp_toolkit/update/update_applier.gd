@tool
extends RefCounted
## Applies a staged toolkit update while the editor closes.
##
## The plugin calls [method apply_pending] from [code]_exit_tree[/code] on every exit
## that is not a disable. Writing the files while the editor runs would let its
## focus-in rescan hot-reload new code onto state the old code built, and writing
## them before a restart could leave them swapped under a running editor when a
## save dialog holds the restart; at exit nothing reloads them. An editor ended by a
## signal or a crash skips the call, and the update waits for the next exit.[br]
## [br]
## The apply re-checks the staged files, copies the installed folder to the backup,
## writes every release file and reads it back, deletes the files the release
## dropped, and on any failure writes the backup back. Each step goes to the install
## log, and the record's state tells the next start what happened.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/update/release_assets.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/update/release_signature.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/update/release_archive.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/update/release_file_list.gd")
const InstallPlan := preload("res://addons/godot_mcp_toolkit/update/install_plan.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/update/install_guards.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")
const TrustedReleaseKeys := preload("res://addons/godot_mcp_toolkit/update/trusted_release_keys.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

## The installed addon folder.
const ADDON_FOLDER := "res://addons/godot_mcp_toolkit"


## Applies the staged update, if there is one.
##
## [param options] replaces what the apply reads, for tests: [code]addon_folder[/code],
## [code]update_folder[/code], [code]engine_version[/code] ([code]major.minor[/code]),
## [code]public_keys[/code] and [code]guard_facts[/code] (the shape
## [method InstallGuards.facts] returns).[br]
## [br]
## Returns [code]{"state": String, "reason": String}[/code]: the record's new state,
## or an empty state when nothing was staged.
static func apply_pending(options: Dictionary = {}) -> Dictionary:
	var addon_folder := ProjectSettings.globalize_path(str(options.get("addon_folder", ADDON_FOLDER)))
	var update_folder := str(options.get("update_folder", PendingUpdate.FOLDER))
	var record := PendingUpdate.read(update_folder)
	if record["state"] != PendingUpdate.STAGED:
		return {"state": "", "reason": ""}
	var version: String = record["version"]
	PendingUpdate.log_line("apply %s over %s started" % [version, record["from_version"]], update_folder)

	var reader := ZIPReader.new()
	var check := _check_staged(version, addon_folder, update_folder, options, reader)
	if not str(check["error"]).is_empty():
		return _finish(record, PendingUpdate.NOT_APPLIED, str(check["error"]), update_folder)
	var release_files: PackedStringArray = check["files"]

	var backup := ProjectSettings.globalize_path(PendingUpdate.backup_folder(update_folder))
	FolderFiles.remove_tree(backup)
	var not_backed_up := FolderFiles.copy_tree(addon_folder, backup)
	if not not_backed_up.is_empty():
		reader.close()
		return _finish(record, PendingUpdate.NOT_APPLIED,
				"could not back up %s" % not_backed_up[0], update_folder)

	var plan := InstallPlan.plan(
			ReleaseFileList.read_installed(addon_folder), FolderFiles.hashes(addon_folder), release_files)
	var failure := ""
	for path in plan["write"]:
		if not FolderFiles.write_checked(addon_folder.path_join(path), ReleaseArchive.read_file(reader, path)):
			failure = "could not write %s" % path
			break
	if failure.is_empty():
		for path in plan["delete"]:
			DirAccess.remove_absolute(addon_folder.path_join(path))
			if FileAccess.file_exists(addon_folder.path_join(path)):
				failure = "could not delete %s" % path
				break
	reader.close()

	if failure.is_empty():
		return _finish(record, PendingUpdate.APPLIED, "", update_folder)
	var not_restored := _restore(backup, addon_folder, plan["write"])
	if not not_restored.is_empty():
		failure += "; %d files were not restored, copy them back from %s" % [not_restored.size(), backup]
	return _finish(record, PendingUpdate.ROLLED_BACK, failure, update_folder)


# Re-checks what the installer checked before staging, on the files as they are now,
# and opens the zip in `reader`, which stays open only when the update may be written.
# Returns the shape ReleaseArchive.inspect_open returns: an empty "error" and the
# release's "files" when the update may be written.
static func _check_staged(
		version: String, addon_folder: String, update_folder: String,
		options: Dictionary, reader: ZIPReader) -> Dictionary:
	var guard_facts: Dictionary = options["guard_facts"] if options.has("guard_facts") else InstallGuards.facts()
	var refusal := InstallGuards.refusal(guard_facts)
	if not refusal.is_empty():
		return _problem(InstallGuards.describe(refusal))

	var staged := PendingUpdate.version_folder(version, update_folder)
	var manifest_bytes := FileAccess.get_file_as_bytes(staged.path_join(ReleaseAssets.manifest_name(version)))
	var signature := FileAccess.get_file_as_bytes(staged.path_join(ReleaseAssets.signature_name(version)))
	var public_keys: Array = options.get("public_keys", TrustedReleaseKeys.PUBLIC_KEYS)
	if not ReleaseSignature.is_valid(manifest_bytes, signature, public_keys):
		return _problem("the update's signature does not verify")
	var manifest := ReleaseManifest.parse(manifest_bytes.get_string_from_utf8(), version)
	if not str(manifest["error"]).is_empty():
		return _problem(str(manifest["error"]))
	var engine_version := str(options.get("engine_version", VersionUtils.get_engine_version_pair()))
	if not ReleaseManifest.supports_engine(manifest, engine_version):
		return _problem("version %s needs Godot %s or newer" % [version, manifest["min_godot"]])

	var archive := staged.path_join(ReleaseAssets.archive_name(version))
	if not FileAccess.file_exists(archive) or FolderFiles.hash_of_file(archive) != manifest["archive_sha256"]:
		return _problem("the staged archive does not match its manifest")
	var installed := installed_version(addon_folder)
	if not UpdateCheck.is_newer(installed, version):
		return _problem("version %s is not newer than the installed %s" % [version, installed])
	if reader.open(archive) != OK:
		return _problem("the staged archive is not a readable zip")
	var inspection := ReleaseArchive.inspect_open(reader, version)
	# Closing a reader that never opened prints an engine error, so a refusal closes
	# only a reader it opened.
	if not str(inspection["error"]).is_empty():
		reader.close()
	return inspection


## The version in [param addon_folder]'s plugin.cfg, or an empty string when it cannot
## be read.
static func installed_version(addon_folder: String) -> String:
	var config := ConfigFile.new()
	if config.load(addon_folder.path_join("plugin.cfg")) != OK:
		return ""
	return str(config.get_value("plugin", "version", ""))


static func _problem(reason: String) -> Dictionary:
	return {"error": reason}


# Writes the backup back over the addon folder, skipping the files the failed apply
# never changed, and deletes the files the update added. Returns the relative paths
# that could not be restored.
static func _restore(backup: String, addon_folder: String, written: PackedStringArray) -> PackedStringArray:
	var backed_up := FolderFiles.list(backup)
	var failed := FolderFiles.copy_tree(backup, addon_folder, true)
	for path in written:
		if backed_up.has(path):
			continue
		DirAccess.remove_absolute(addon_folder.path_join(path))
		if FileAccess.file_exists(addon_folder.path_join(path)):
			failed.append(path)
	return failed


static func _finish(record: Dictionary, state: String, reason: String, update_folder: String) -> Dictionary:
	record["state"] = state
	record["reason"] = reason
	PendingUpdate.write(record, update_folder)
	PendingUpdate.log_line("apply %s: %s%s" % [record["version"], state,
			"" if reason.is_empty() else " (%s)" % reason], update_folder)
	return {"state": state, "reason": reason}
