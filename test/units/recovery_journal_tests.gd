@tool
extends RefCounted
## Unit tests for the recovery plugin's journal reader and decision: it reads every pinned
## journal as UpdateJournal does and rejects what that rejects, its decision table, when a
## restart is awaited, when it stays out of an editor, and when a stage may roll forward.

const Testing := preload("res://test/units/testing.gd")
const UpdateJournal := preload("res://addons/godot_mcp_toolkit/self_update/update_journal.gd")
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const ReleaseFileList := preload("res://addons/godot_mcp_toolkit/self_update/release_file_list.gd")
const UpdateApplier := preload("res://addons/godot_mcp_toolkit/self_update/update_applier.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")

# The template has no class_name, so the tests load it by its path.
const RECOVERY_JOURNAL_PATH := "res://addons/godot_mcp_toolkit/self_update/recovery/recovery_journal.gd"
# The fields the recovery reader shares with UpdateJournal.read.
const SHARED_FIELDS := ["state", "from", "to", "backup", "expected_tree_hash", "applying_at", "restored"]
const PINNED_HASH := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
const APPLYING_AT := 1794300000


static func run(testing: Testing) -> void:
	var reader: GDScript = load(RECOVERY_JOURNAL_PATH)
	_test_pinned_journals(testing, reader)
	_test_agrees_with_update_journal(testing, reader)
	_test_plugin_version(testing, reader)
	_test_decide_never(testing, reader)
	_test_decide_age(testing, reader)
	_test_decide_applying_without_folder(testing, reader)
	_test_decide_live_version(testing, reader)
	_test_decide_finishes_restore(testing, reader)
	_test_decide_removes_itself(testing, reader)
	_test_decide_enabled_but_not_started(testing, reader)
	_test_awaits_restart(testing, reader)
	_test_stays_out(testing, reader)
	_test_stage_matches(testing, reader)


static func _write_journal(folder: String, text: String) -> void:
	FolderFiles.write_checked(ProjectSettings.globalize_path(folder).path_join("journal.json"), text.to_utf8_buffer())


# UpdateJournal's record cut to the fields the recovery reader returns, each only when present.
static func _shared(record: Dictionary) -> Dictionary:
	var shared := {}
	for field: String in SHARED_FIELDS:
		if record.has(field):
			shared[field] = record[field]
	return shared


# Both readers' records of the given journal text, in a folder of its own.
static func _read_both(reader: GDScript, purpose: String, text: String) -> Array[Dictionary]:
	var folder := UpdateFixtures.scratch(purpose)
	_write_journal(folder, text)
	var recovery: Dictionary = reader.call("read", folder)
	var update := UpdateJournal.read(folder)
	UpdateFixtures.remove(folder)
	var both: Array[Dictionary] = [recovery, _shared(update)]
	return both


static func _test_pinned_journals(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery journal: every journal 1.2.0 writes reads as UpdateJournal reads it")
	var pinned := {
		"staged": UpdateFixtures.PINNED_1_2_0_JOURNAL,
		"applying": UpdateFixtures.PINNED_1_2_0_APPLYING_JOURNAL,
		"applied": UpdateFixtures.PINNED_1_2_0_APPLIED_JOURNAL,
		"not_applied": UpdateFixtures.PINNED_1_2_0_RESTORED_JOURNAL,
	}
	var expected := {
		"staged": {"state": "staged", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
				"expected_tree_hash": PINNED_HASH},
		"applying": {"state": "applying", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
				"expected_tree_hash": PINNED_HASH, "applying_at": APPLYING_AT},
		"applied": {"state": "applied", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
				"expected_tree_hash": PINNED_HASH, "applying_at": APPLYING_AT},
		"not_applied": {"state": "not_applied", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
				"expected_tree_hash": PINNED_HASH, "applying_at": APPLYING_AT, "restored": true},
	}
	for state: String in pinned:
		var records := _read_both(reader, "recovery_pinned_" + state, str(pinned[state]))
		testing.eq(records[1], expected[state], "%s: UpdateJournal reads the shared fields" % state)
		testing.eq(records[0], expected[state], "%s: the recovery reader reads the same" % state)
	print("")


static func _test_agrees_with_update_journal(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery journal: rejects what UpdateJournal rejects, and keeps what it keeps")
	var valid := {"format": 1, "state": "applying", "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
			"expected_tree_hash": PINNED_HASH, "applying_at": APPLYING_AT}
	var texts := {
		"broken JSON": "{broken",
		"cut short": "{\"format\": 1, \"state\": \"applying\", \"from\": \"1.1",
		"an array": "[1, 2]",
		"empty": "",
	}
	var changes := {
		"format 2": {"format": 2},
		"format as text": {"format": "1"},
		"no format": {"format": null},
		"unknown state": {"state": "rolled_back"},
		"state not text": {"state": 3},
		"no state": {"state": null},
		"to escapes": {"to": "../../evil"},
		"to two parts": {"to": "1.2"},
		"to prerelease": {"to": "1.2.0-beta"},
		"to a number": {"to": 3},
		"no to": {"to": null},
		"from escapes": {"from": "../../evil"},
		"from empty": {"from": ""},
		"no from": {"from": null},
		"backup escapes": {"backup": "../../addons"},
		"backup of another version": {"backup": "backup-1.0.0"},
		"backup the stage": {"backup": "stage"},
		"backup a number": {"backup": 3},
		"versions with a v and spaces": {"from": " v1.1.0", "backup": "backup- v1.1.0"},
		"hash not text": {"expected_tree_hash": 4},
		"applying_at negative": {"applying_at": -5},
		"applying_at text": {"applying_at": "soon"},
		"applying_at fractional": {"applying_at": 1794300000.75},
		"restored text": {"restored": "yes"},
		"restored false": {"restored": false},
		"restored true": {"restored": true},
		"a later key": {"a_later_key": "value"},
	}
	for label: String in changes:
		var fields := valid.duplicate()
		var change: Dictionary = changes[label]
		for key: String in change:
			if change[key] == null:
				fields.erase(key)
			else:
				fields[key] = change[key]
		texts[label] = JSON.stringify(fields)
	for label: String in texts:
		var records := _read_both(reader, "recovery_agree_%d" % texts.keys().find(label), str(texts[label]))
		testing.eq(records[0], records[1], "%s → the same record" % label)
	var missing: Dictionary = reader.call("read", UpdateFixtures.scratch("recovery_no_journal"))
	testing.eq(str(missing.get("state", "missing")), "", "no journal file → an empty state")
	var rejected := _read_both(reader, "recovery_rejected", "{broken")
	testing.eq(str(rejected[0].get("state", "missing")), "", "a rejected journal → an empty state")
	print("")


static func _test_plugin_version(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery journal: the version a plugin.cfg names")
	var folder := UpdateFixtures.scratch("recovery_plugin_version")
	var absolute := ProjectSettings.globalize_path(folder)
	FolderFiles.write_checked(absolute.path_join("plugin.cfg"), UpdateFixtures.plugin_config("1.2.0").to_utf8_buffer())
	FolderFiles.write_checked(absolute.path_join("broken.cfg"), "[plugin\nversion=".to_utf8_buffer())
	var printed := Engine.print_error_messages
	Engine.print_error_messages = false
	var version: Variant = reader.call("plugin_version", folder.path_join("plugin.cfg"))
	var missing: Variant = reader.call("plugin_version", folder.path_join("none.cfg"))
	var broken: Variant = reader.call("plugin_version", folder.path_join("broken.cfg"))
	Engine.print_error_messages = printed
	UpdateFixtures.remove(folder)
	testing.eq(version, "1.2.0", "a readable plugin.cfg → its version")
	testing.eq(missing, "", "no file → empty")
	testing.eq(broken, "", "a file that does not parse → empty")
	print("")


# A journal as the reader returns it; applying_at only when that argument is set.
static func _journal(state: String, applying_at: int = -1) -> Dictionary:
	var journal := {"state": state, "from": "1.1.0", "to": "1.2.0", "backup": "backup-1.1.0",
			"expected_tree_hash": PINNED_HASH}
	if applying_at >= 0:
		journal["applying_at"] = applying_at
	return journal


# A windowed editor where the toolkit did not load and the version that broke it is live.
static func _facts(changes: Dictionary = {}) -> Dictionary:
	var facts := {
		"toolkit_enabled": false,
		"stays_out": false,
		"addon_present": true,
		"live_version": "1.2.0",
		"backup_present": true,
		"stage_whole": false,
		"broken_present": false,
	}
	facts.merge(changes, true)
	return facts


static func _decision(reader: GDScript, journal: Dictionary, facts: Dictionary, now: int) -> Dictionary:
	var verdict: Dictionary = reader.call("decide", journal, facts, now)
	return verdict


static func _act(action: String) -> Dictionary:
	return {"action": action, "seconds": 0}


static func _test_decide_never(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: never acts where Q4 rules it out")
	var now := APPLYING_AT + 1000
	var aged := _journal("applying", APPLYING_AT)
	testing.eq(_decision(reader, _journal("applied"), _facts(), now), _act("restore"),
			"the control: applied, the toolkit off, a windowed editor → restore")
	testing.eq(_decision(reader, _journal(""), _facts(), now), _act("none"), "no journal → none")
	testing.eq(_decision(reader, _journal("verified"), _facts(), now), _act("none"), "verified → none")
	testing.eq(_decision(reader, _journal("staged"), _facts(), now), _act("none"), "staged → none")
	testing.eq(_decision(reader, _journal("not_applied"), _facts(), now), _act("none"), "not applied → none")
	var restored := _journal("not_applied")
	restored["restored"] = true
	testing.eq(_decision(reader, restored, _facts(), now), _act("none"), "not applied and restored → none")
	testing.eq(_decision(reader, _journal("applied"), _facts({"toolkit_enabled": true, "live_version": "1.1.0"}), now),
			_act("none"), "applied with the toolkit enabled and the old version live → none")
	testing.eq(_decision(reader, _journal("applied"), _facts({"stays_out": true}), now), _act("none"),
			"applied in an editor it stays out of → none")
	testing.eq(_decision(reader, aged, _facts({"toolkit_enabled": true}), now), _act("none"),
			"an aged applying with the toolkit enabled → none")
	testing.eq(_decision(reader, aged, _facts({"stays_out": true, "addon_present": false, "stage_whole": true}), now),
			_act("none"), "an aged applying in an editor it stays out of → none")
	testing.eq(_decision(reader, _journal(""), _facts({"stays_out": true, "addon_present": false}), now),
			_act("none"), "no journal and no addon folder, in an editor it stays out of → none")
	print("")


static func _test_decide_age(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: an applying journal waits out its first 60 s either way")
	var facts := _facts({"addon_present": false, "stage_whole": true})
	var journal := _journal("applying", APPLYING_AT)
	testing.eq(_decision(reader, journal, facts, APPLYING_AT + 59), {"action": "wait", "seconds": 2},
			"59 s old → wait 2 s")
	testing.eq(_decision(reader, journal, facts, APPLYING_AT + 60), {"action": "wait", "seconds": 1},
			"60 s old → wait 1 s")
	testing.eq(_decision(reader, journal, facts, APPLYING_AT + 61), _act("roll_forward"), "61 s old → acts")
	testing.eq(_decision(reader, journal, facts, APPLYING_AT), {"action": "wait", "seconds": 61},
			"written this second → wait 61 s")
	testing.eq(_decision(reader, journal, facts, APPLYING_AT - 59), {"action": "wait", "seconds": 120},
			"59 s ahead → wait until 61 s old")
	testing.eq(_decision(reader, journal, facts, APPLYING_AT - 61), _act("roll_forward"), "61 s ahead → acts")
	testing.eq(_decision(reader, _journal("applying"), facts, APPLYING_AT), _act("roll_forward"),
			"no applying time → acts")
	testing.eq(_decision(reader, _journal("applying", APPLYING_AT), _facts(), APPLYING_AT + 59),
			{"action": "wait", "seconds": 2}, "59 s old with the addon folder present → wait 2 s")
	print("")


static func _test_decide_applying_without_folder(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: an aged applying journal with no addon folder")
	var now := APPLYING_AT + 1000
	var journal := _journal("applying", APPLYING_AT)
	testing.eq(_decision(reader, journal, _facts({"addon_present": false, "stage_whole": true}), now),
			_act("roll_forward"), "the stage whole → roll forward")
	testing.eq(_decision(reader, journal, _facts({"addon_present": false, "stage_whole": true, "backup_present": false}),
			now), _act("roll_forward"), "the stage whole and no backup → roll forward")
	testing.eq(_decision(reader, journal, _facts({"addon_present": false}), now), _act("roll_back"),
			"the stage not whole, a backup → roll back")
	testing.eq(_decision(reader, journal, _facts({"addon_present": false, "backup_present": false}), now),
			_act("manual"), "the stage not whole, no backup → manual")
	print("")


static func _test_decide_live_version(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: with the addon folder present, the live version decides")
	var now := APPLYING_AT + 1000
	var aged := _journal("applying", APPLYING_AT)
	testing.eq(_decision(reader, aged, _facts({"live_version": "1.2.0"}), now), _act("restore"),
			"applying, the new version live → restore")
	testing.eq(_decision(reader, aged, _facts({"live_version": "1.1.0"}), now), _act("none"),
			"applying, the old version live → none")
	testing.eq(_decision(reader, aged, _facts({"live_version": "1.3.0"}), now), _act("manual"),
			"applying, another version live → manual")
	testing.eq(_decision(reader, aged, _facts({"live_version": ""}), now), _act("manual"),
			"applying, no readable version → manual")
	testing.eq(_decision(reader, aged, _facts({"backup_present": false}), now), _act("manual"),
			"applying, the new version live and no backup → manual")
	var applied := _journal("applied", APPLYING_AT)
	testing.eq(_decision(reader, applied, _facts({"live_version": "1.2.0"}), now), _act("restore"),
			"applied, the new version live → restore")
	testing.eq(_decision(reader, applied, _facts({"live_version": "1.1.0"}), now), _act("manual"),
			"applied, the old version live and no broken folder → manual")
	testing.eq(_decision(reader, applied, _facts({"live_version": "1.3.0"}), now), _act("manual"),
			"applied, another version live → manual")
	testing.eq(_decision(reader, applied, _facts({"backup_present": false}), now), _act("manual"),
			"applied, the new version live and no backup → manual")
	testing.eq(_decision(reader, applied, _facts({"addon_present": false, "live_version": ""}), now),
			_act("restore"), "applied, no addon folder, a backup → restore")
	testing.eq(_decision(reader, applied, _facts({"addon_present": false, "live_version": "", "backup_present": false}),
			now), _act("manual"), "applied, no addon folder, no backup → manual")
	print("")


static func _test_decide_finishes_restore(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: the old version live beside broken-<to> → the restore is finished")
	var now := APPLYING_AT + 1000
	# What a crash between the backup's rename in and the journal write leaves.
	var crashed := _facts({"live_version": "1.1.0", "backup_present": false, "broken_present": true})
	testing.eq(_decision(reader, _journal("applied", APPLYING_AT), crashed, now), _act("finish_restore"),
			"applied, the old version live, broken-<to> aside → finish the restore")
	testing.eq(_decision(reader, _journal("applying", APPLYING_AT), crashed, now), _act("finish_restore"),
			"an aged applying, the old version live, broken-<to> aside → finish the restore")
	testing.eq(_decision(reader, _journal("applying", APPLYING_AT), crashed, APPLYING_AT + 10),
			{"action": "wait", "seconds": 51}, "a young applying, the old version live, broken-<to> aside → wait")
	testing.eq(_decision(reader, _journal("applied", APPLYING_AT),
			_facts({"live_version": "1.1.0", "broken_present": true}), now), _act("finish_restore"),
			"applied, the old version live, broken-<to> aside and a backup → finish the restore")
	crashed["toolkit_enabled"] = true
	testing.eq(_decision(reader, _journal("applied", APPLYING_AT), crashed, now), _act("none"),
			"the same with the toolkit enabled → none: the toolkit's own settle reads it")
	testing.eq(_decision(reader, _journal("applied", APPLYING_AT),
			_facts({"live_version": "1.3.0", "broken_present": true}), now), _act("manual"),
			"applied, another version live, broken-<to> aside → manual")
	testing.eq(_decision(reader, _journal("applied", APPLYING_AT), _facts({"broken_present": true}), now),
			_act("restore"), "applied, the new version live, a stale broken-<to> → restore")
	print("")


static func _test_decide_removes_itself(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: no addon folder and no update in flight → it removes itself")
	var now := APPLYING_AT + 1000
	var gone := _facts({"addon_present": false, "live_version": ""})
	for state: String in ["", "verified", "staged", "not_applied"]:
		testing.eq(_decision(reader, _journal(state), gone, now), _act("remove_self"),
				"state '%s', no addon folder → remove itself" % state)
	testing.eq(_decision(reader, _journal("applying", APPLYING_AT), gone, APPLYING_AT + 10),
			{"action": "wait", "seconds": 51}, "a young applying, no addon folder → wait, not remove")
	testing.eq(_decision(reader, _journal("applied"), gone, now), _act("restore"),
			"applied, no addon folder → restore, not remove")
	print("")


# An editor that enabled the toolkit from a stale class cache and never started it, with the
# version the journal went to live: only a restart loads it.
static func _test_decide_enabled_but_not_started(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery decision: applied with the toolkit enabled and its new version live → one more restart")
	var now := APPLYING_AT + 1000
	var applied := _journal("applied")
	var enabled := _facts({"toolkit_enabled": true})
	testing.eq(_decision(reader, applied, enabled, now), _act("restart_needed"),
			"applied with the toolkit enabled, the new version live → restart needed")
	var asked := _facts({"toolkit_enabled": true, "restart_asked": true})
	testing.eq(_decision(reader, applied, asked, now), _act("manual"),
			"the same with the restart already asked for → manual")
	testing.eq(_decision(reader, applied, _facts({"toolkit_enabled": true, "live_version": "1.3.0"}), now),
			_act("none"), "the toolkit enabled, another version live → none")
	testing.eq(_decision(reader, applied, _facts({"toolkit_enabled": true, "live_version": ""}), now),
			_act("none"), "the toolkit enabled, no readable version → none")
	testing.eq(_decision(reader, applied, _facts({"toolkit_enabled": true, "addon_present": false}), now),
			_act("none"), "the toolkit enabled, no addon folder → none")
	testing.eq(_decision(reader, applied, _facts({"toolkit_enabled": true, "stays_out": true}), now),
			_act("none"), "the toolkit enabled, in an editor it stays out of → none")
	print("")


static func _awaits_restart(reader: GDScript, journal: Dictionary) -> Variant:
	var awaits: Variant = reader.call("awaits_restart", journal)
	return awaits


static func _test_awaits_restart(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery journal: a restart is awaited while an update is applying, applied or restored")
	var restored := _journal("not_applied")
	restored["restored"] = true
	testing.eq(_awaits_restart(reader, restored), true, "not applied and restored → true")
	testing.eq(_awaits_restart(reader, _journal("applied")), true, "applied → true")
	testing.eq(_awaits_restart(reader, _journal("applying", APPLYING_AT)), true, "applying → true")
	for state: String in ["", "verified", "staged", "not_applied"]:
		testing.eq(_awaits_restart(reader, _journal(state)), false, "state '%s' → false" % state)
	print("")


static func _test_stays_out(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery plugin: stays out of headless and command-line runs")
	var rows := [
		[true, [], true, "a headless editor"],
		[false, [], false, "a windowed editor, no arguments"],
		[false, ["--editor", "--path", "project"], false, "a windowed editor with a path"],
		[false, ["--export-release", "Windows", "out.exe"], true, "--export-release"],
		[false, ["--export-debug", "Windows", "out.exe"], true, "--export-debug"],
		[false, ["--export-pack", "Windows", "out.pck"], true, "--export-pack"],
		[false, ["--export-patch", "Windows", "out.pck"], true, "--export-patch"],
		[false, ["--export", "Windows"], true, "--export"],
		[false, ["--path", "project", "--quit"], true, "--quit"],
		[false, ["--quit-after", "5"], true, "--quit-after"],
		[false, ["--script", "tool.gd"], true, "--script"],
		[false, ["-s", "tool.gd"], true, "-s, the short --script"],
		[false, ["--quitter", "--scripted", "-script"], false, "an argument that only looks like one"],
		[false, ["--import"], true, "--import"],
		[false, ["--path", "project", "--import"], true, "--import after a path"],
		[false, ["--importer", "--import-all", "-import"], false, "an argument that only looks like --import"],
	]
	for row: Array in rows:
		var arguments := PackedStringArray(row[1] as Array)
		var stays_out: Variant = reader.call("stays_out", bool(row[0]), arguments)
		testing.eq(stays_out, bool(row[2]), "%s → %s" % [str(row[3]), "stays out" if bool(row[2]) else "runs"])
	print("")


# Writes a stage holding files and the list of their hashes. Returns the list's hash.
static func _write_stage(stage: String, files: Dictionary) -> String:
	var listed := {}
	for path: String in files:
		var bytes := str(files[path]).to_utf8_buffer()
		FolderFiles.write_checked(stage.path_join(path), bytes)
		listed[path] = ContentHash.of_bytes(bytes)
	var list_bytes := ReleaseFileList.format(listed).to_utf8_buffer()
	FolderFiles.write_checked(stage.path_join(ReleaseFileList.FILE_NAME), list_bytes)
	return ContentHash.of_bytes(list_bytes)


static func _matches(reader: GDScript, stage: String, expected_tree_hash: String) -> bool:
	var matches: Variant = reader.call("stage_matches", stage, expected_tree_hash)
	return bool(matches)


static func _test_stage_matches(testing: Testing, reader: GDScript) -> void:
	testing.begin("Recovery journal: a stage rolls forward only when it is the signed release")
	var folder := UpdateFixtures.scratch("recovery_stage")
	var stage := ProjectSettings.globalize_path(folder).path_join("stage")
	var files := {"plugin.cfg": UpdateFixtures.plugin_config("1.2.0"), "core/a.gd": "a", "core/b.gd": "b"}
	var tree_hash := _write_stage(stage, files)
	var list_bytes := FileAccess.get_file_as_bytes(stage.path_join(ReleaseFileList.FILE_NAME))
	var agrees := {}
	var whole := _matches(reader, stage, tree_hash)
	agrees["the whole stage"] = _applier_agrees(reader, stage, list_bytes)
	var other_hash := _matches(reader, stage, PINNED_HASH)
	var no_hash := _matches(reader, stage, "")
	FolderFiles.write_checked(stage.path_join("core/a.gd"), "tampered".to_utf8_buffer())
	var tampered := _matches(reader, stage, tree_hash)
	agrees["a tampered file"] = _applier_agrees(reader, stage, list_bytes)
	FolderFiles.write_checked(stage.path_join("core/a.gd"), "a".to_utf8_buffer())
	FolderFiles.write_checked(stage.path_join("core/extra.gd"), "extra".to_utf8_buffer())
	var extra := _matches(reader, stage, tree_hash)
	agrees["an extra file"] = _applier_agrees(reader, stage, list_bytes)
	DirAccess.remove_absolute(stage.path_join("core/extra.gd"))
	FolderFiles.write_checked(stage.path_join(".hidden"), "hidden".to_utf8_buffer())
	var hidden_extra := _matches(reader, stage, tree_hash)
	agrees["an extra hidden file"] = _applier_agrees(reader, stage, list_bytes)
	DirAccess.remove_absolute(stage.path_join(".hidden"))
	DirAccess.remove_absolute(stage.path_join("core/b.gd"))
	var missing := _matches(reader, stage, tree_hash)
	agrees["a missing file"] = _applier_agrees(reader, stage, list_bytes)
	FolderFiles.write_checked(stage.path_join("core/b.gd"), "b".to_utf8_buffer())
	var whole_again := _matches(reader, stage, tree_hash)
	agrees["the file put back"] = _applier_agrees(reader, stage, list_bytes)
	var forged_files := files.duplicate()
	forged_files["core/a.gd"] = "forged"
	var forged_hash := _write_stage(stage, forged_files)
	var forged_bytes := FileAccess.get_file_as_bytes(stage.path_join(ReleaseFileList.FILE_NAME))
	var forged := _matches(reader, stage, tree_hash)
	agrees["a forged list"] = _applier_agrees(reader, stage, list_bytes)
	var forged_own := _matches(reader, stage, forged_hash)
	agrees["the forged stage under its own list"] = _applier_agrees(reader, stage, forged_bytes)
	var no_stage := _matches(reader, stage.path_join("none"), tree_hash)
	agrees["no stage"] = _applier_agrees(reader, stage.path_join("none"), list_bytes)
	UpdateFixtures.remove(folder)
	testing.ok(whole, "the whole stage under its list's hash → true")
	testing.ok(not other_hash, "the whole stage under another hash → false")
	testing.ok(not no_hash, "no expected hash → false")
	testing.ok(not tampered, "a tampered file → false")
	testing.ok(not extra, "an extra file → false")
	testing.ok(not hidden_extra, "an extra hidden file → false")
	testing.ok(not missing, "a missing file → false")
	testing.ok(whole_again, "the file put back → true")
	testing.ok(not forged, "a list forged to match a changed file → false")
	testing.ok(forged_own, "the control: the forged stage under its own list's hash → true")
	testing.ok(not no_stage, "no stage → false")
	for label: String in agrees:
		testing.ok(bool(agrees[label]), "%s → UpdateApplier.stage_matches says the same" % label)
	print("")


# Whether UpdateApplier.stage_matches, given the list as the signed zip holds it, says what
# the recovery reader says given that list's hash.
static func _applier_agrees(reader: GDScript, stage: String, list_bytes: PackedByteArray) -> bool:
	return UpdateApplier.stage_matches(stage, list_bytes) == _matches(reader, stage, ContentHash.of_bytes(list_bytes))
