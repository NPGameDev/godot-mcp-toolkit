@tool
extends Node
## Verifies and stages the toolkit updates the install mode allows, and reports what
## the last apply did.
##
## The composer adds the installer beside the update check runner, whose newer,
## undismissed version it follows. When the install mode, the consent gate, the
## trusted keys and the install guards allow it, the installer downloads the release's
## manifest and signature and verifies them ([constant AVAILABLE]); then, on the
## user's word or at once in the automatic mode, it downloads the zip, checks it
## against the manifest and stages it ([constant READY]). The editor's next exit
## applies it (see [code]update_applier.gd[/code]); nothing here writes the addon
## folder.[br]
## [br]
## A verified manifest and a staged zip are kept in [code]user://[/code], so an editor
## start finds them again without a request. Failures before the user asked are
## silent, like the update check's; after a click on Update they show in the badge.
## Every URL is built from the version (see [code]release_assets.gd[/code]).

## Emitted when anything the badge or the prompt shows may have changed.
signal state_changed

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const HttpIdentity := preload("res://addons/godot_mcp_toolkit/core/http_identity.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/update/install_mode.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/update/install_guards.gd")
const InstallPlan := preload("res://addons/godot_mcp_toolkit/update/install_plan.gd")
const PendingUpdate := preload("res://addons/godot_mcp_toolkit/update/pending_update.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/update/release_assets.gd")
const ReleaseArchive := preload("res://addons/godot_mcp_toolkit/update/release_archive.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/update/release_file_list.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/update/release_signature.gd")
const TrustedReleaseKeys := preload("res://addons/godot_mcp_toolkit/update/trusted_release_keys.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/update/folder_files.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/update/update_applier.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")

## [method state] values. [constant IDLE]: nothing to install, the badge links only.
const IDLE := "idle"
## A verified release waits for the user's word.
const AVAILABLE := "available"
## The zip is downloading.
const DOWNLOADING := "downloading"
## The zip is staged; the editor's next exit installs it.
const READY := "ready"
## The last attempt the user asked for failed; [method error_text] says why.
const FAILED := "failed"

## [method notice] kinds.
const NOTICE_UPDATED := "updated"
const NOTICE_FAILED := "failed"

const _MANIFEST_TIMEOUT_SEC := 15.0
const _ARCHIVE_TIMEOUT_SEC := 120.0

# Which reply the HTTPRequest waits for.
const _WAITING_NONE := 0
const _WAITING_MANIFEST := 1
const _WAITING_SIGNATURE := 2
const _WAITING_ARCHIVE := 3

var _runner: UpdateCheckRunner = null
var _update_folder: String = PendingUpdate.FOLDER
var _addon_folder: String = UpdateApplier.ADDON_FOLDER
var _public_keys: Array = TrustedReleaseKeys.PUBLIC_KEYS
# Where the install mode is read: [ProjectSettings] or a test's stand-in.
var _project_settings: Object = ProjectSettings
# The install guards' facts, or an empty dictionary to read them from the project.
var _guard_facts: Dictionary = {}
var _http: HTTPRequest = null
var _waiting: int = _WAITING_NONE
var _state: String = IDLE
var _version: String = ""
var _error: String = ""
# Why a guard stops the install, from the last evaluation.
var _guard_note: String = ""
# The Godot floor of a verified release this editor is below, and its version.
var _floor_note: String = ""
var _floor_version: String = ""
var _changed_files := PackedStringArray()
var _manifest := {}
var _manifest_bytes := PackedByteArray()
# The last apply's result, shown until the user closes it.
var _notice := {}
# Whether the running attempt came from a click, so its failure is shown.
var _user_asked: bool = false
# The version this session already tried to verify, and to download on its own in
# the automatic mode, so a failure is not retried on every change the runner or
# the project settings report. A click on Update always tries again.
var _verify_tried: String = ""
var _download_tried: String = ""
# The version this session verified or downloaded itself, as opposed to one picked up
# from a record an earlier session left.
var _found_version: String = ""


## [param runner] is the update check runner whose version the installer follows.
## [param options] replaces what the installer reads, for tests:
## [code]update_folder[/code], [code]addon_folder[/code], [code]public_keys[/code],
## [code]guard_facts[/code] (the shape [method InstallGuards.facts] returns) and
## [code]project_settings[/code] (a stand-in [method InstallMode.read] accepts).
func _init(runner: UpdateCheckRunner, options: Dictionary = {}) -> void:
	_runner = runner
	_update_folder = str(options.get("update_folder", PendingUpdate.FOLDER))
	_addon_folder = str(options.get("addon_folder", UpdateApplier.ADDON_FOLDER))
	_public_keys = options.get("public_keys", TrustedReleaseKeys.PUBLIC_KEYS)
	_guard_facts = options.get("guard_facts", {})
	_project_settings = options.get("project_settings", ProjectSettings)


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_read_last_apply()
	if _runner != null:
		_runner.state_changed.connect(_evaluate)
	ProjectSettings.settings_changed.connect(_evaluate)
	_evaluate()


func _exit_tree() -> void:
	if _runner != null and is_instance_valid(_runner) and _runner.state_changed.is_connected(_evaluate):
		_runner.state_changed.disconnect(_evaluate)
	if ProjectSettings.settings_changed.is_connected(_evaluate):
		ProjectSettings.settings_changed.disconnect(_evaluate)
	if _http != null:
		_http.cancel_request()
	_waiting = _WAITING_NONE


## One of [constant IDLE], [constant AVAILABLE], [constant DOWNLOADING],
## [constant READY] or [constant FAILED].
func state() -> String:
	return _state


## The version the state is about ([code]X.Y.Z[/code]), empty in [constant IDLE].
func version() -> String:
	return _version


## Why the last attempt failed, for [constant FAILED].
func error_text() -> String:
	return _error


## Why the newer version cannot be installed from the editor (a guard, or a Godot
## floor above this editor), or an empty string.
func note_text() -> String:
	if not _guard_note.is_empty():
		return _guard_note
	return _floor_note if _floor_version == _version else ""


## The installed toolkit files that differ from the installed release's list.
func changed_files() -> PackedStringArray:
	return _changed_files


## The project's install mode, read live.
func install_mode() -> String:
	return InstallMode.read(_project_settings)


## The install log's path, as the user would open it.
func log_path() -> String:
	return PendingUpdate.log_path(_update_folder)


## Whether this session verified or downloaded [method version] itself, rather than
## picking it up from a record an earlier session left.
func found_this_session() -> bool:
	return not _version.is_empty() and _found_version == _version


## The last apply's result while it is shown: [code]{"kind": NOTICE_UPDATED or
## NOTICE_FAILED, "version", "from_version", "reason", "server_changed": bool}[/code],
## or an empty dictionary.
func notice() -> Dictionary:
	return _notice


## Stops showing the last apply's result.
func clear_notice() -> void:
	_notice = {}
	state_changed.emit()


## Whether the editor-start window should ask about [method version]: the mode asks,
## the release is verified, and nothing was changed by hand.
func prompt_due() -> bool:
	return _state == AVAILABLE and install_mode() == InstallMode.ASK


## Downloads and stages [method version], on the user's word.
func install() -> void:
	if _state != AVAILABLE and _state != FAILED:
		return
	_user_asked = true
	if _manifest.is_empty():
		_verify_tried = ""
		_start_verify(_version)
	else:
		_download_archive()


## Gives up [method version]: deletes what was downloaded and hides the version until
## a newer one.
func discard() -> void:
	_cancel()
	PendingUpdate.clear(_update_folder)
	if _runner != null and not _version.is_empty():
		_runner.dismiss(_version)
	_set_state(IDLE)


## Saves the scenes and restarts the editor, whose exit installs the staged update.
## The restart is deferred so it runs outside the caller: the editor frees its
## plugins while it exits, and a plugin function still on the stack would crash it.
## When Godot asks about unsaved scripts and the user cancels, nothing is installed.
func restart_now() -> void:
	if _state != READY:
		return
	EditorInterface.save_all_scenes()
	EditorInterface.call_deferred("restart_editor", false)


# Decides, from the runner's version and the gates, what the installer should be
# doing, and starts it.
func _evaluate() -> void:
	if _waiting != _WAITING_NONE:
		return
	var newer: String = _runner.badge_version() if _runner != null else ""
	# A failure the user saw stays until they act on it.
	if _state == FAILED and newer == _version:
		return
	var record := PendingUpdate.read(_update_folder)
	if newer.is_empty() or not _install_allowed(newer):
		if record["state"] == PendingUpdate.VERIFIED or record["state"] == PendingUpdate.STAGED:
			PendingUpdate.clear(_update_folder)
		_version = newer
		_set_state(IDLE)
		return
	_version = newer
	if record["version"] == newer and _restore_record(record):
		return
	if _verify_tried != newer:
		_start_verify(newer)


# Whether the gates let `newer` be installed from the editor; sets _guard_note when
# a guard is the reason.
func _install_allowed(newer: String) -> bool:
	_guard_note = ""
	if not Consent.may_install_updates(install_mode()) or _public_keys.is_empty():
		return false
	if _runner.is_major():
		return false
	var refusal := InstallGuards.refusal(_guard_facts if not _guard_facts.is_empty() else InstallGuards.facts())
	if not refusal.is_empty():
		_guard_note = InstallGuards.describe(refusal)
		return false
	return UpdateCheck.is_newer(_installed_version(), newer)


# Picks up a verified or staged record of the version the runner reports, after
# checking its files again. Returns whether it did.
func _restore_record(record: Dictionary) -> bool:
	var version: String = record["version"]
	var folder := PendingUpdate.version_folder(version, _update_folder)
	var manifest_bytes := FileAccess.get_file_as_bytes(folder.path_join(ReleaseAssets.manifest_name(version)))
	var signature := FileAccess.get_file_as_bytes(folder.path_join(ReleaseAssets.signature_name(version)))
	if not ReleaseSignature.is_valid(manifest_bytes, signature, _public_keys):
		PendingUpdate.clear(_update_folder)
		return false
	var manifest := ReleaseManifest.parse(manifest_bytes.get_string_from_utf8(), version)
	if not str(manifest["error"]).is_empty():
		PendingUpdate.clear(_update_folder)
		return false
	_manifest = manifest
	_manifest_bytes = manifest_bytes
	_changed_files = record["changed_files"]
	if record["state"] == PendingUpdate.STAGED:
		var archive := ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.archive_name(version)))
		if FolderFiles.hash_of_file(archive) == str(manifest["archive_sha256"]):
			_set_state(READY)
			return true
		_write_record(PendingUpdate.VERIFIED)
	_set_state(AVAILABLE)
	_continue_automatically()
	return true


func _start_verify(version: String) -> void:
	_verify_tried = version
	_manifest = {}
	_manifest_bytes = PackedByteArray()
	_send(ReleaseAssets.manifest_name(version), _WAITING_MANIFEST, ReleaseManifest.MAX_BYTES, "", _MANIFEST_TIMEOUT_SEC)


func _download_archive() -> void:
	var folder := ProjectSettings.globalize_path(PendingUpdate.version_folder(_version, _update_folder))
	DirAccess.make_dir_recursive_absolute(folder)
	_set_state(DOWNLOADING)
	_send(ReleaseAssets.archive_name(_version), _WAITING_ARCHIVE, int(_manifest["archive_size"]),
			folder.path_join(ReleaseAssets.archive_name(_version)), _ARCHIVE_TIMEOUT_SEC)


func _send(asset: String, waiting: int, size_limit: int, target_file: String, timeout: float) -> void:
	_http.download_file = target_file
	_http.body_size_limit = size_limit
	_http.timeout = timeout
	var url := ReleaseAssets.download_url(OS.get_environment(UpdateCheck.HOST_ENV), _version, asset)
	var error := _http.request(url, HttpIdentity.request_headers(), HTTPClient.METHOD_GET)
	_waiting = waiting if error == OK else _WAITING_NONE
	if error != OK:
		_fail("the download could not start (error %d)" % error)


func _on_request_completed(
		result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var waiting := _waiting
	_waiting = _WAITING_NONE
	_http.download_file = ""
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		# Up to Godot 4.6, HTTPRequest leaves what it wrote of a failed download.
		if waiting == _WAITING_ARCHIVE:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(
					PendingUpdate.version_folder(_version, _update_folder).path_join(ReleaseAssets.archive_name(_version))))
		_fail("the download failed (result %d, HTTP %d)" % [result, response_code])
		return
	match waiting:
		_WAITING_MANIFEST:
			_manifest_bytes = body
			_send(ReleaseAssets.signature_name(_version), _WAITING_SIGNATURE, ReleaseSignature.MAX_BYTES, "", _MANIFEST_TIMEOUT_SEC)
		_WAITING_SIGNATURE:
			_on_signature(body)
		_WAITING_ARCHIVE:
			_on_archive()


func _on_signature(signature: PackedByteArray) -> void:
	if not ReleaseSignature.is_valid(_manifest_bytes, signature, _public_keys):
		_fail("version %s is not signed by a trusted key" % _version)
		return
	var manifest := ReleaseManifest.parse(_manifest_bytes.get_string_from_utf8(), _version)
	if not str(manifest["error"]).is_empty():
		_fail(str(manifest["error"]))
		return
	if not ReleaseManifest.supports_engine(manifest, VersionUtils.get_engine_version_pair()):
		_floor_note = "Version %s needs Godot %s or newer." % [_version, manifest["min_godot"]]
		_floor_version = _version
		_user_asked = false
		_set_state(IDLE)
		return
	_manifest = manifest
	var addon := ProjectSettings.globalize_path(_addon_folder)
	_changed_files = InstallPlan.plan(
			ReleaseFileList.read_installed(addon), FolderFiles.hashes(addon), PackedStringArray())["changed"]
	var folder := PendingUpdate.version_folder(_version, _update_folder)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if not FolderFiles.write_checked(ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.manifest_name(_version))), _manifest_bytes) \
			or not FolderFiles.write_checked(ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.signature_name(_version))), signature):
		_fail("could not keep the verified manifest")
		return
	_write_record(PendingUpdate.VERIFIED)
	_found_version = _version
	_set_state(AVAILABLE)
	if _user_asked:
		_download_archive()
	else:
		_continue_automatically()


func _on_archive() -> void:
	var archive := ProjectSettings.globalize_path(
			PendingUpdate.version_folder(_version, _update_folder).path_join(ReleaseAssets.archive_name(_version)))
	if FolderFiles.hash_of_file(archive) != str(_manifest["archive_sha256"]):
		DirAccess.remove_absolute(archive)
		_fail("the downloaded archive does not match the manifest")
		return
	var layout := ReleaseArchive.inspect(archive, _version)
	if not str(layout["error"]).is_empty():
		DirAccess.remove_absolute(archive)
		_fail(str(layout["error"]))
		return
	_write_record(PendingUpdate.STAGED)
	_user_asked = false
	_found_version = _version
	_set_state(READY)


# In the automatic mode a verified release downloads at once, once per session,
# unless installed files were changed by hand: then the user decides, as in the ask
# mode.
func _continue_automatically() -> void:
	if install_mode() != InstallMode.AUTOMATIC or not _changed_files.is_empty() or _download_tried == _version:
		return
	_download_tried = _version
	_download_archive()


func _write_record(state: String) -> void:
	PendingUpdate.write({
		"state": state,
		"version": _version,
		"from_version": _installed_version(),
		"compatible_server": VersionUtils.COMPATIBLE_SERVER_VERSION,
		"changed_files": _changed_files,
	}, _update_folder)
	PendingUpdate.log_line("%s %s" % [state, _version], _update_folder)


# A failure the user asked to see goes to FAILED; any other leaves the badge as links.
func _fail(reason: String) -> void:
	PendingUpdate.log_line("%s: %s" % [_version, reason], _update_folder)
	if _user_asked:
		_user_asked = false
		_error = reason
		_set_state(FAILED)
		return
	_set_state(IDLE)


func _cancel() -> void:
	if _http != null:
		_http.cancel_request()
		_http.download_file = ""
	_waiting = _WAITING_NONE
	_user_asked = false


# Reads what the editor's last exit did with a staged update, turns it into the
# notice, and deletes the files it no longer needs.
func _read_last_apply() -> void:
	var record := PendingUpdate.read(_update_folder)
	var state: String = record["state"]
	if state != PendingUpdate.APPLIED and state != PendingUpdate.ROLLED_BACK and state != PendingUpdate.NOT_APPLIED:
		return
	var running := _installed_version()
	var updated: bool = state == PendingUpdate.APPLIED and running == str(record["version"])
	_notice = {
		"kind": NOTICE_UPDATED if updated else NOTICE_FAILED,
		"version": record["version"],
		"from_version": record["from_version"],
		"reason": record["reason"] if not updated else "",
		"server_changed": updated and record["compatible_server"] != VersionUtils.COMPATIBLE_SERVER_VERSION,
	}
	if state == PendingUpdate.APPLIED and not updated:
		_notice["reason"] = "the editor started version %s" % running
	# A rollback that could not restore every file names the backup; keep it then.
	PendingUpdate.clear(_update_folder, str(record["reason"]).contains("copy them back"))


# The version in the addon folder's plugin.cfg: the running toolkit's, since the
# folder is only written while the editor closes.
func _installed_version() -> String:
	return UpdateApplier.installed_version(ProjectSettings.globalize_path(_addon_folder))


func _set_state(state: String) -> void:
	_state = state
	if state != FAILED:
		_error = ""
	state_changed.emit()
