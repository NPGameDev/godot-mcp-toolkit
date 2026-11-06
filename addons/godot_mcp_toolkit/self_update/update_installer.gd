@tool
extends Node
## Verifies and stages the toolkit updates the install mode allows, and reports what
## the last apply did.
##
## The composer adds the installer beside the update check runner, whose newer,
## undismissed version it follows. When the install mode, the consent gate, the
## embedded trust document and the install guards allow it, the installer downloads the release's
## manifest and signature and verifies them ([constant AVAILABLE]); then, on the
## user's word, it downloads the zip, checks it against the manifest and stages it a few
## files a frame ([constant PREPARING], then [constant READY]). The editor's next exit
## applies it (see [code]update_applier.gd[/code]); nothing here writes the addon folder.
## While a release is staged, [method version] names it, whichever newer version the runner reports, and
## nothing newer is fetched. A staged release whose files still check out stays until
## [method discard] or the [code]manual[/code] install mode deletes it; that mode also calls
## off a download or a stage that is running.[br]
## [br]
## A verified manifest and a staged zip are kept in the update folder (see
## [code]update_folder.gd[/code]), so an editor start finds them again without a request.[br]
## [br]
## Just before a verify, and on every click on Update, the installer fetches the trust
## documents this machine lacks, one at a time, until a 404 or the chain's cap for one walk.
## A failed check leaves [constant IDLE] with [method note_text] saying what failed, and a
## click retries it ([method can_retry_check]). A failed download after a click goes to
## [constant FAILED]. While an update is staged no check runs.[br]
## [br]
## When staging ends, the restart gate (see [code]restart_gate.gd[/code]) restarts the
## editor or opens the ready view, which [method ready_view] reports.[br]
## [br]
## Every URL is built from the version (see [code]release_assets.gd[/code]), and a reply can
## redirect it only to the hosts [code]update_downloader.gd[/code] allows.

## Emitted when anything the badge or the prompt shows may have changed.
signal state_changed

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const InstallMode := preload("res://addons/godot_mcp_toolkit/self_update/install_mode.gd")
const InstallGuards := preload("res://addons/godot_mcp_toolkit/self_update/install_guards.gd")
const InstallPlan := preload("res://addons/godot_mcp_toolkit/self_update/install_plan.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const UpdateSettler := preload("res://addons/godot_mcp_toolkit/self_update/update_settler.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const StageRunner := preload("res://addons/godot_mcp_toolkit/self_update/stage_runner.gd")
const StageStepper := preload("res://addons/godot_mcp_toolkit/self_update/stage_stepper.gd")
const UpdateLifecycle := preload("res://addons/godot_mcp_toolkit/self_update/update_lifecycle.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/self_update/release_manifest.gd")
const ReleaseSignature := preload("res://addons/godot_mcp_toolkit/self_update/release_signature.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateDownloader := preload("res://addons/godot_mcp_toolkit/self_update/update_downloader.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const UpdateCheckFailure := preload("res://addons/godot_mcp_toolkit/self_update/update_check_failure.gd")
const TrustChain := preload("res://addons/godot_mcp_toolkit/self_update/trust_chain.gd")
const RestartGate := preload("res://addons/godot_mcp_toolkit/self_update/restart_gate.gd")
const EditorRestartProbe := preload("res://addons/godot_mcp_toolkit/self_update/editor_restart_probe.gd")

## [method state] values. [constant IDLE]: nothing to install, the badge links only.
const IDLE := "idle"
## A verified release waits for the user's word.
const AVAILABLE := "available"
## A click on Update is running: the trust documents, then the zip.
const DOWNLOADING := "downloading"
## The zip checked out and is being unpacked into the stage.
const PREPARING := "preparing"
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
const _WAITING_TRUST_DOCUMENT := 4
const _WAITING_STAGE := 5

var _runner: UpdateCheckRunner = null
var _update_folder: String = UpdateFolder.FOLDER
var _addon_folder: String = InstallGuards.ADDON_FOLDER
# What the constructor was given, in the names the settler and the trust chain read.
var _options: Dictionary = {}
# Where the install mode is read: [ProjectSettings] or a test's stand-in.
var _project_settings: Object = ProjectSettings
# The install guards' facts, or an empty dictionary to read them from the project.
var _guard_facts: Dictionary = {}
var _downloader: UpdateDownloader = null
var _stage_runner: StageRunner = null
var _restart_gate: RestartGate = null
# Decided once: whether this editor is headless does not change while it runs.
var _stays_out: bool = false
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
# The files in the addon folder that the release does not list, which an install deletes.
var _discarded_files := PackedStringArray()
var _manifest := {}
var _manifest_bytes := PackedByteArray()
# The last apply's result, shown until the user closes it.
var _notice := {}
var _settled := {}
# Whether the running attempt came from a click, so its failure is shown.
var _user_asked: bool = false
# The version this session already tried to verify, so a failure is not retried on
# every change the runner or the project settings report. A click on Update always
# tries again.
var _verify_tried: String = ""
# The version this session verified or downloaded itself, as opposed to one picked up
# from what an earlier session left.
var _found_version: String = ""
# The chain the running walk moves along; its cap counts per instance.
var _walk: TrustChain = null
# The last check's failure (an UpdateCheckFailure kind) and its sentence.
var _check_failure: String = ""
var _check_note: String = ""
var _check_timeout_sec: float = _MANIFEST_TIMEOUT_SEC


## [param runner] is the update check runner whose version the installer follows.
## [param options] replaces what the installer reads, for tests:
## [code]update_folder[/code], [code]addon_folder[/code], [code]trust_document[/code] and
## [code]trust_store[/code] (the shape [method ReleaseSignature.chain] takes),
## [code]guard_facts[/code] (the shape [method InstallGuards.facts] returns),
## [code]project_settings[/code] (a stand-in [method InstallMode.read] accepts),
## [code]check_timeout_sec[/code] (each request of a check),
## [code]stage_budget_ms[/code] (each frame's staging) and [code]restart_probe[/code]
## (a stand-in for [code]editor_restart_probe.gd[/code]).
func _init(runner: UpdateCheckRunner, options: Dictionary = {}) -> void:
	_runner = runner
	_options = options
	_stays_out = UpdateLifecycle.stays_out(options)
	_check_timeout_sec = float(options.get("check_timeout_sec", _MANIFEST_TIMEOUT_SEC))
	_update_folder = str(options.get("update_folder", UpdateFolder.FOLDER))
	_addon_folder = str(options.get("addon_folder", InstallGuards.ADDON_FOLDER))
	_guard_facts = options.get("guard_facts", {})
	_project_settings = options.get("project_settings", ProjectSettings)
	var probe: EditorRestartProbe = options.get("restart_probe", null)
	_restart_gate = RestartGate.new(probe if probe != null else EditorRestartProbe.new())
	_restart_gate.view_changed.connect(_on_view_changed)


func _ready() -> void:
	_downloader = UpdateDownloader.new()
	_downloader.finished.connect(_on_fetched)
	add_child(_downloader)
	_stage_runner = StageRunner.new(int(_options.get("stage_budget_ms", StageStepper.BUDGET_MS)))
	_stage_runner.finished.connect(_on_staged)
	add_child(_stage_runner)
	_settle_last_update()
	if _runner != null:
		_runner.state_changed.connect(_evaluate)
	ProjectSettings.settings_changed.connect(_evaluate)
	_evaluate()


func _exit_tree() -> void:
	if _runner != null and is_instance_valid(_runner) and _runner.state_changed.is_connected(_evaluate):
		_runner.state_changed.disconnect(_evaluate)
	if ProjectSettings.settings_changed.is_connected(_evaluate):
		ProjectSettings.settings_changed.disconnect(_evaluate)
	if _downloader != null:
		_downloader.cancel()
	if _stage_runner != null:
		_stage_runner.cancel()
	_restart_gate.cancel()
	_waiting = _WAITING_NONE


## One of [constant IDLE], [constant AVAILABLE], [constant DOWNLOADING],
## [constant PREPARING], [constant READY] or [constant FAILED].
func state() -> String:
	return _state


## The version the state is about ([code]X.Y.Z[/code]), empty in [constant IDLE].
func version() -> String:
	return _version


## Why the last attempt failed, for [constant FAILED].
func error_text() -> String:
	return _error


## Why the newer version cannot be installed from the editor (a guard, a failed check, or a
## Godot floor above this editor), or an empty string.
func note_text() -> String:
	if not _guard_note.is_empty():
		return _guard_note
	if not _check_note.is_empty():
		return _check_note
	return _floor_note if _floor_version == _version else ""


## Whether the last check failed, so the badge says why.
func check_failed() -> bool:
	return not _check_failure.is_empty()


## Whether a click on Update can retry the check that failed.
func can_retry_check() -> bool:
	return UpdateCheckFailure.can_retry(_check_failure)


## Whether the check that failed was refused on security grounds, so the badge offers no
## download of the release it refused.
func security_check_failed() -> bool:
	return _check_failure == UpdateCheckFailure.SECURITY


## The installed toolkit files that differ from the installed release's list.
func changed_files() -> PackedStringArray:
	return _changed_files


## The files in the addon folder that the release does not list: installing deletes them.
## Read while an update is offered; a staged update found at an editor start leaves it empty.
func discarded_files() -> PackedStringArray:
	return _discarded_files


## The ready view while it is open (the shape [code]restart_gate.gd[/code]'s view returns),
## or an empty dictionary.
func ready_view() -> Dictionary:
	return _restart_gate.view()


## Closes the ready view; the staged update still installs when the editor closes.
func close_ready_view() -> void:
	_restart_gate.close_view()


## Decides again what the installer should be doing, as a settings change does.
func reevaluate() -> void:
	_evaluate()


## The project's install mode, read live.
func install_mode() -> String:
	return InstallMode.read(_project_settings)


## The install log's path, as the user would open it.
func log_path() -> String:
	return UpdateFolder.log_path(_update_folder)


## Whether this session verified or downloaded [method version] itself, rather than
## picking it up from what an earlier session left.
func found_this_session() -> bool:
	return not _version.is_empty() and _found_version == _version


## The last apply's result while it is shown: [code]{"kind": NOTICE_UPDATED or
## NOTICE_FAILED, "version", "from_version", "reason", "server_changed": bool}[/code],
## or an empty dictionary.
func notice() -> Dictionary:
	return _notice


## What the settle at this editor's start found: what [method UpdateSettler.settle] returns,
## or an empty dictionary when this editor stays out of the update folder. Unlike
## [method notice] it holds every report, the waiting one and its reason included.
func settled() -> Dictionary:
	return _settled


## Why the editor's last exit left the staged update uninstalled, while that update is
## still [constant READY] and named by [method version]; an empty string otherwise, and when
## the exit has not tried to install it yet.
func postponed_reason() -> String:
	if _state != READY or str(_settled.get("report", "")) != UpdateSettler.WAITING:
		return ""
	if str(_settled.get("to", "")) != _version:
		return ""
	return str(_settled.get("reason", ""))


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
	if _state != AVAILABLE and _state != FAILED and not can_retry_check():
		return
	_user_asked = true
	_verify_tried = _version
	_set_state(DOWNLOADING)
	_start_walk()


## Gives up [method version]: deletes what was downloaded and hides the version until
## a newer one.
func discard() -> void:
	_withdraw(_version)


## Restarts the editor, whose exit installs the staged update, unless a script has unsaved
## edits: then the ready view opens and says so. Nothing is saved first.
func restart_now() -> void:
	if _state != READY:
		return
	_restart_gate.restart()


# Decides, from the runner's version and the gates, what the installer should be
# doing, and starts it.
func _evaluate() -> void:
	if _waiting != _WAITING_NONE:
		# The manual mode calls off a running download or stage; anything else waits for it.
		if install_mode() != InstallMode.MANUAL:
			return
		_withdraw()
	var newer: String = _runner.badge_version() if _runner != null else ""
	# The gates below would clear what a journal and a kept manifest hold, and an update
	# waiting for its real exit must outlive a build or an import.
	if _stays_out:
		_guard_note = InstallGuards.describe(InstallGuards.HEADLESS)
		_version = newer
		_set_state(IDLE)
		return
	# A failure the user saw stays until they act on it.
	if _state == FAILED and newer == _version:
		return
	var record := UpdateJournal.read(_update_folder)
	if record["state"] == UpdateJournal.STAGED and install_mode() == InstallMode.MANUAL:
		UpdateJournal.clear(_update_folder)
		record = UpdateJournal.read(_update_folder)
	# The staged release stands, whichever newer one the runner reports, or none: the editor's
	# exit installs it, and the newer one is offered at the next start.
	# It skips the gates below, as the exit checks the guards, the trust and the version order again.
	if record["state"] == UpdateJournal.STAGED:
		_version = record["to"]
		if _restore_record(record, newer):
			return
		record = UpdateJournal.read(_update_folder)
	var record_state: String = record["state"]
	if newer.is_empty() or not _install_allowed(newer):
		# A journal this version cannot read stays with its files, as it does at a settle:
		# a later version may have written it.
		if record_state == UpdateJournal.VERIFIED or record_state == UpdateJournal.STAGED or not UpdateJournal.exists(_update_folder):
			UpdateJournal.clear(_update_folder)
		_version = newer
		_set_state(IDLE)
		return
	# A failed check stays until a click or a new start, even over a kept release, whose
	# trust that same check could not confirm.
	if newer == _version and check_failed():
		return
	_version = newer
	if record["to"] == newer and _restore_record(record, newer):
		return
	if record_state.is_empty() and _restore_kept(newer):
		return
	if _verify_tried != newer:
		_start_verify(newer)


# Whether the gates let `version` be installed from the editor; sets _guard_note when
# a guard is the reason.
func _install_allowed(version: String) -> bool:
	_guard_note = ""
	if not Consent.may_install_updates(install_mode()) or not ReleaseSignature.has_chain(_options):
		return false
	var installed := _installed_version()
	if UpdateCheck.is_major_bump(installed, version):
		return false
	var refusal := InstallGuards.refusal(_guard_facts if not _guard_facts.is_empty() else InstallGuards.facts())
	if not refusal.is_empty():
		_guard_note = InstallGuards.describe(refusal)
		return false
	return UpdateCheck.is_newer(installed, version)


# Picks up the release the journal names, which _version already holds, after checking
# its files again. Returns whether that decided the state; if not, the record is gone and
# the caller goes on to `newer`, the version the runner reports.
func _restore_record(record: Dictionary, newer: String) -> bool:
	var version: String = record["to"]
	# A verified journal stands for a download that never finished, so it goes with
	# whatever that left, as it does at a settle.
	var kept: Dictionary = {} if record["state"] == UpdateJournal.VERIFIED else _read_kept(version)
	if kept.is_empty():
		if record["state"] == UpdateJournal.STAGED and _kept_signature_refused(version):
			_notice_not_installed(record, UpdateApplier.UNTRUSTED_SIGNATURE)
		UpdateJournal.clear(_update_folder)
		_set_state(IDLE)
		return false
	var manifest: Dictionary = kept["manifest"]
	var restored_state := AVAILABLE
	if record["state"] == UpdateJournal.STAGED:
		var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path(version, _update_folder))
		if FolderFiles.hash_of_file(archive) == str(manifest["archive_sha256"]):
			restored_state = READY
		elif not _keep_only_verified():
			_fail("could not delete a staged zip that no longer matches its manifest")
			return true
		elif version != newer:
			_set_state(IDLE)
			return false
	_manifest = manifest
	_manifest_bytes = kept["bytes"]
	_changed_files = record["changed_files"]
	var found_at_start := restored_state == READY and _state != READY
	_set_state(restored_state)
	if found_at_start:
		_restart_gate.show_view()
	return true


# Offers the release an earlier session verified, whose manifest and signature wait in
# the update folder with no journal. Returns whether they answered for `version`, so
# nothing needs fetching.
func _restore_kept(version: String) -> bool:
	var kept := _read_kept(version)
	if kept.is_empty():
		return false
	var manifest: Dictionary = kept["manifest"]
	if not ReleaseManifest.supports_engine(manifest, VersionUtils.get_engine_version_pair()):
		_note_engine_floor(manifest)
		return true
	# Hashing the addon folder is the slow part, and every settings change lands here.
	if kept["bytes"] != _manifest_bytes:
		_read_local_changes()
	_manifest = manifest
	_manifest_bytes = kept["bytes"]
	_set_state(AVAILABLE)
	return true


# The update folder's manifest of `version`, checked again: {"manifest": what
# ReleaseManifest.parse returns, "bytes": its text}, or an empty dictionary when it or
# its signature is missing or does not check out.
func _read_kept(version: String) -> Dictionary:
	var folder := UpdateFolder.version_folder(version, _update_folder)
	var manifest_path := folder.path_join(ReleaseAssets.manifest_name(version))
	var signature_path := folder.path_join(ReleaseAssets.signature_name(version))
	if not FileAccess.file_exists(manifest_path) or not FileAccess.file_exists(signature_path):
		return {}
	var manifest_bytes := FileAccess.get_file_as_bytes(manifest_path)
	var signature := FileAccess.get_file_as_bytes(signature_path)
	if not ReleaseSignature.is_trusted(manifest_bytes, signature, null, _options):
		return {}
	var manifest := ReleaseManifest.parse(manifest_bytes.get_string_from_utf8(), version)
	if not str(manifest["error"]).is_empty():
		return {}
	return {"manifest": manifest, "bytes": manifest_bytes}


# Whether the update folder holds the manifest and signature of `version` and the chain no
# longer trusts that signature, as when a key was dropped after the release was staged.
func _kept_signature_refused(version: String) -> bool:
	var folder := UpdateFolder.version_folder(version, _update_folder)
	var manifest_path := folder.path_join(ReleaseAssets.manifest_name(version))
	var signature_path := folder.path_join(ReleaseAssets.signature_name(version))
	if not FileAccess.file_exists(manifest_path) or not FileAccess.file_exists(signature_path):
		return false
	return not ReleaseSignature.is_trusted(
			FileAccess.get_file_as_bytes(manifest_path), FileAccess.get_file_as_bytes(signature_path), null, _options)


# The notice for a staged release the exit will not install, the one the exit's own refusal
# reaches through a settle.
func _notice_not_installed(record: Dictionary, reason: String) -> void:
	UpdateFolder.log_line("%s: %s" % [record["to"], reason], _update_folder)
	_notice = {
		"kind": NOTICE_FAILED,
		"version": record["to"],
		"from_version": record["from"],
		"reason": reason,
		"server_changed": false,
	}


# Drops what a download or a stage left, back to the verified manifest and signature
# with no journal. The journal goes last and only when the rest is gone: while it stands,
# the next start deals with whatever this could not delete. Returns whether the journal
# went; a caller already failing for another reason has nothing to add.
func _keep_only_verified() -> bool:
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path(_version, _update_folder))
	if FileAccess.file_exists(archive) and DirAccess.remove_absolute(archive) != OK:
		return false
	if not FolderFiles.remove_tree(ProjectSettings.globalize_path(UpdateFolder.stage_folder(_update_folder))):
		return false
	UpdateJournal.remove(_update_folder)
	return not UpdateJournal.exists(_update_folder)


func _start_verify(version: String) -> void:
	_verify_tried = version
	_manifest = {}
	_manifest_bytes = PackedByteArray()
	_start_walk()


func _start_walk() -> void:
	# A note about an earlier check says nothing about this one.
	if check_failed():
		_set_state(_state)
	_walk = ReleaseSignature.chain(_options)
	if not _walk.has_store():
		_fail_check(UpdateCheckFailure.NO_DATA_FOLDER, "the data folder is not an absolute path")
		return
	_fetch_next_document()


func _fetch_next_document() -> void:
	var number := _walk.next_version()
	if number == 0:
		_end_walk()
		return
	var url := ReleaseAssets.trust_document_url(OS.get_environment(UpdateCheck.HOST_ENV), number)
	if _downloader.fetch(url, TrustChain.MAX_FILE_BYTES, _check_timeout_sec) != OK:
		_fail_check(UpdateCheckFailure.UNREACHABLE, "the fetch of trust document %d could not start" % number)
		return
	_waiting = _WAITING_TRUST_DOCUMENT


func _on_trust_document(outcome: Dictionary) -> void:
	if bool(outcome["ok"]):
		var accepted := _walk.accept(outcome["body"])
		if str(accepted["outcome"]) == TrustChain.ACCEPTED:
			_fetch_next_document()
		else:
			_fail_check(UpdateCheckFailure.of_accept(str(accepted["outcome"])), str(accepted["reason"]))
	elif int(outcome["result"]) == HTTPRequest.RESULT_SUCCESS and int(outcome["code"]) == 404:
		_end_walk()
	else:
		_fail_check(UpdateCheckFailure.of_fetch(outcome), _fetch_problem(outcome))


# The walk moved the chain, so what was verified before it is verified again. A kept release
# that no longer holds is fetched anew, and its own signature then decides.
func _end_walk() -> void:
	if _walk.release_keys().is_empty():
		_fail_check(UpdateCheckFailure.SECURITY, "the latest trust document lists no release key")
		return
	_walk = null
	if not _manifest.is_empty():
		var kept := _read_kept(_version)
		if not kept.is_empty():
			_manifest = kept["manifest"]
			_manifest_bytes = kept["bytes"]
			_download_archive()
			return
		_manifest = {}
		_manifest_bytes = PackedByteArray()
	_send(ReleaseAssets.manifest_name(_version), _WAITING_MANIFEST, ReleaseManifest.MAX_BYTES, "", _check_timeout_sec)


static func _fetch_problem(outcome: Dictionary) -> String:
	var refusal := str(outcome["refusal"])
	return refusal if not refusal.is_empty() else "the download failed (result %d, HTTP %d)" % [int(outcome["result"]), int(outcome["code"])]


func _download_archive() -> void:
	# The journal comes before the first byte: a kill mid-download leaves a partial zip,
	# and only this record makes the next start clear it. The settler clears a verified
	# journal with its folder at every start, so nothing writes one earlier.
	if not UpdateFolder.ensure_ignore_files(_update_folder) or not _write_record(UpdateJournal.VERIFIED):
		_fail("could not write to the update folder")
		return
	var folder := ProjectSettings.globalize_path(UpdateFolder.version_folder(_version, _update_folder))
	DirAccess.make_dir_recursive_absolute(folder)
	_set_state(DOWNLOADING)
	_send(ReleaseAssets.archive_name(_version), _WAITING_ARCHIVE, int(_manifest["archive_size"]),
			folder.path_join(ReleaseAssets.archive_name(_version)), _ARCHIVE_TIMEOUT_SEC)


func _send(asset: String, waiting: int, size_limit: int, target_file: String, timeout: float) -> void:
	var url := ReleaseAssets.download_url(OS.get_environment(UpdateCheck.HOST_ENV), _version, asset)
	var error := _downloader.fetch(url, size_limit, timeout, target_file)
	_waiting = waiting if error == OK else _WAITING_NONE
	if error != OK:
		if waiting == _WAITING_ARCHIVE:
			_keep_only_verified()
			_fail("the download could not start (error %d)" % error)
		else:
			_fail_check(UpdateCheckFailure.UNREACHABLE, "the download could not start (error %d)" % error)


func _on_fetched(outcome: Dictionary) -> void:
	var waiting := _waiting
	_waiting = _WAITING_NONE
	if waiting == _WAITING_TRUST_DOCUMENT:
		_on_trust_document(outcome)
		return
	if not bool(outcome["ok"]):
		if waiting == _WAITING_ARCHIVE:
			_keep_only_verified()
			_fail(_fetch_problem(outcome))
		else:
			_fail_check(UpdateCheckFailure.of_release_file(outcome), _fetch_problem(outcome))
		return
	match waiting:
		_WAITING_MANIFEST:
			_manifest_bytes = outcome["body"]
			_send(ReleaseAssets.signature_name(_version), _WAITING_SIGNATURE, ReleaseSignature.MAX_BYTES, "", _check_timeout_sec)
		_WAITING_SIGNATURE:
			_on_signature(outcome["body"])
		_WAITING_ARCHIVE:
			_on_archive()


func _on_signature(signature: PackedByteArray) -> void:
	if not ReleaseSignature.is_trusted(_manifest_bytes, signature, null, _options):
		_fail_check(UpdateCheckFailure.SECURITY, "version %s is not signed by a trusted key" % _version)
		return
	var manifest := ReleaseManifest.parse(_manifest_bytes.get_string_from_utf8(), _version)
	if not str(manifest["error"]).is_empty():
		_fail_check(UpdateCheckFailure.SECURITY, str(manifest["error"]))
		return
	if not ReleaseManifest.supports_engine(manifest, VersionUtils.get_engine_version_pair()):
		_note_engine_floor(manifest)
		return
	_manifest = manifest
	_read_local_changes()
	# What a download of another release left goes. A staged release is never cleared
	# here: it stands until the editor's exit installs it.
	if UpdateJournal.read(_update_folder)["state"] == UpdateJournal.VERIFIED:
		UpdateJournal.clear(_update_folder)
	var folder := UpdateFolder.version_folder(_version, _update_folder)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if not UpdateFolder.ensure_ignore_files(_update_folder) \
			or not FolderFiles.write_checked(ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.manifest_name(_version))), _manifest_bytes) \
			or not FolderFiles.write_checked(ProjectSettings.globalize_path(folder.path_join(ReleaseAssets.signature_name(_version))), signature):
		_fail("could not keep the verified manifest")
		return
	_found_version = _version
	_set_state(AVAILABLE)
	if _user_asked:
		_download_archive()


func _note_engine_floor(manifest: Dictionary) -> void:
	_floor_note = "Version %s needs Godot %s or newer." % [_version, manifest["min_godot"]]
	_floor_version = _version
	_user_asked = false
	_set_state(IDLE)


# Reads which installed toolkit files differ from the installed release's list, and which
# files the list does not name, from one hash of the addon folder.
func _read_local_changes() -> void:
	var addon := ProjectSettings.globalize_path(_addon_folder)
	var plan := InstallPlan.plan(ReleaseFileList.read_installed(addon), FolderFiles.hashes(addon))
	_changed_files = plan["changed"]
	_discarded_files = plan["discarded"]


func _on_archive() -> void:
	var archive := ProjectSettings.globalize_path(UpdateFolder.archive_path(_version, _update_folder))
	if FolderFiles.hash_of_file(archive) != str(_manifest["archive_sha256"]):
		_keep_only_verified()
		_fail("the downloaded archive does not match the manifest")
		return
	_waiting = _WAITING_STAGE
	# The run exists before the state says so: a handler of that state can discard the update,
	# and the discard has to find something to cancel.
	_stage_runner.start(_version, _update_folder)
	_set_state(PREPARING)


func _on_staged(outcome: Dictionary) -> void:
	_waiting = _WAITING_NONE
	if str(outcome["state"]) != StageStepper.DONE:
		_keep_only_verified()
		_fail(str(outcome["reason"]))
		return
	if not _write_record(UpdateJournal.STAGED):
		_fail("could not write to the update folder")
		return
	_user_asked = false
	_found_version = _version
	_set_state(READY)
	_restart_gate.after_staging()


func _on_view_changed() -> void:
	state_changed.emit()


# Returns whether the journal now holds the record.
func _write_record(state: String) -> bool:
	var written := UpdateJournal.write({
		"state": state,
		"to": _version,
		"from": _installed_version(),
		"compatible_server": VersionUtils.COMPATIBLE_SERVER_VERSION,
		"changed_files": _changed_files,
	}, _update_folder)
	if written:
		UpdateFolder.log_line("%s %s" % [state, _version], _update_folder)
	return written


# A failure the user asked to see goes to FAILED; any other leaves the badge as links.
func _fail(reason: String) -> void:
	UpdateFolder.log_line("%s: %s" % [_version, reason], _update_folder)
	if _user_asked:
		_user_asked = false
		_error = reason
		_set_state(FAILED)
		return
	_set_state(IDLE)


# A check that failed says why, clicked or not; `reason` is for the log. The one exception is a
# release not ready at a start nobody clicked: its files can simply be still on their way, so it
# leaves the plain offer, with nothing to dismiss by reflex, and a later start verifies again.
func _fail_check(kind: String, reason: String) -> void:
	UpdateFolder.log_line("%s: %s" % [_version, reason], _update_folder)
	var waits_quietly := kind == UpdateCheckFailure.NOT_READY and not _user_asked
	var note := UpdateCheckFailure.message(kind, _walk.store() if _walk != null else "")
	_walk = null
	_user_asked = false
	if waits_quietly:
		_set_state(IDLE)
		return
	_set_state(IDLE, kind, note)


# Calls off what is running and deletes what was downloaded, then dismisses
# `dismissed_version` at the runner, if one is given, before the state goes back to IDLE.
func _withdraw(dismissed_version: String = "") -> void:
	_cancel()
	UpdateJournal.clear(_update_folder)
	if _runner != null and not dismissed_version.is_empty():
		_runner.dismiss(dismissed_version)
	_set_state(IDLE)


func _cancel() -> void:
	if _downloader != null:
		_downloader.cancel()
	if _stage_runner != null:
		_stage_runner.cancel()
	_waiting = _WAITING_NONE
	_walk = null
	_user_asked = false


# Settles what the editor's last exit left and turns a result worth showing into the
# notice.
func _settle_last_update() -> void:
	_settled = UpdateLifecycle.settle_at_start(_options)
	var report := str(_settled.get("report", ""))
	if report != UpdateSettler.UPDATED and report != UpdateSettler.FAILED:
		return
	var updated := report == UpdateSettler.UPDATED
	_notice = {
		"kind": NOTICE_UPDATED if updated else NOTICE_FAILED,
		"version": _settled["to"],
		"from_version": _settled["from"],
		"reason": _settled["reason"],
		"server_changed": updated and _settled["compatible_server"] != VersionUtils.COMPATIBLE_SERVER_VERSION,
	}


# The version in the addon folder's plugin.cfg: the running toolkit's, since the
# folder is only written while the editor closes.
func _installed_version() -> String:
	return UpdateApplier.installed_version(ProjectSettings.globalize_path(_addon_folder))


func _set_state(state: String, check_failure: String = "", check_note: String = "") -> void:
	_state = state
	_check_failure = check_failure
	_check_note = check_note
	if state != FAILED:
		_error = ""
	if state != READY:
		_restart_gate.cancel()
	state_changed.emit()
