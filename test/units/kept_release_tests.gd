@tool
extends RefCounted
## Unit tests for reading a verified release's kept files back from the update folder: which
## files make a kept release, when a kept manifest still checks out, and when the chain refuses
## a kept signature, through kept_release.gd's static functions.

const Testing := preload("res://test/units/testing.gd")
const KeptRelease := preload("res://addons/godot_mcp_toolkit/self_update/kept_release.gd")
const UpdateFolder := preload("res://addons/godot_mcp_toolkit/self_update/update_folder.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const FolderFiles := preload("res://addons/godot_mcp_toolkit/self_update/folder_files.gd")
const UpdateFixtures := preload("res://test/units/update_fixtures.gd")
const TrustFixtures := preload("res://test/units/trust_fixtures.gd")

const _VERSION := "1.9.0"


static func run(testing: Testing) -> void:
	_test_files_of_a_kept_release(testing)
	_test_files_with_one_missing(testing)
	_test_read_of_a_trusted_release(testing)
	_test_read_of_a_release_that_fails_its_check(testing)
	_test_signature_refused(testing)


# The release's manifest and signature by `signing_key`, by asset name.
static func _assets(signing_key: CryptoKey) -> Dictionary:
	return UpdateFixtures.release_assets(_VERSION, {"core/a.gd": "new"}, signing_key)


# What ReleaseSignature.chain reads: an embedded document listing UpdateFixtures.key(), and a
# store no case writes.
static func _options(purpose: String) -> Dictionary:
	return {
		"trust_document": TrustFixtures.first_document([UpdateFixtures.key()]),
		"trust_store": UpdateFixtures.scratch("kept_" + purpose + "_trust"),
	}


# Writes each of `asset_names` from `assets` into the version folder of `update_folder`.
static func _keep(update_folder: String, assets: Dictionary, asset_names: Array) -> void:
	var folder := ProjectSettings.globalize_path(UpdateFolder.version_folder(_VERSION, update_folder))
	for asset_name: String in asset_names:
		FolderFiles.write_checked(folder.path_join(asset_name), assets[asset_name])


static func _both() -> Array:
	return [ReleaseAssets.manifest_name(_VERSION), ReleaseAssets.signature_name(_VERSION)]


static func _test_files_of_a_kept_release(testing: Testing) -> void:
	testing.begin("Kept release: the manifest and signature in the version folder are its files")
	var assets := _assets(UpdateFixtures.key())
	var update_folder := UpdateFixtures.scratch("kept_files")
	_keep(update_folder, assets, _both())
	var kept := KeptRelease.files(_VERSION, update_folder)
	UpdateFixtures.remove(update_folder)
	testing.eq(kept, {
		"manifest": assets[ReleaseAssets.manifest_name(_VERSION)],
		"signature": assets[ReleaseAssets.signature_name(_VERSION)],
	}, "both files kept → their bytes, under manifest and signature")
	print("")


static func _test_files_with_one_missing(testing: Testing) -> void:
	testing.begin("Kept release: a version folder missing either file holds no kept release")
	var assets := _assets(UpdateFixtures.key())
	var cases := {
		"the manifest alone": [ReleaseAssets.manifest_name(_VERSION)],
		"the signature alone": [ReleaseAssets.signature_name(_VERSION)],
		"neither file": [],
	}
	var results := {}
	for label: String in cases:
		var update_folder := UpdateFixtures.scratch("kept_missing")
		_keep(update_folder, assets, cases[label])
		results[label] = KeptRelease.files(_VERSION, update_folder)
		UpdateFixtures.remove(update_folder)
	for label: String in cases:
		testing.eq(results[label], {}, "%s → an empty dictionary" % label)
	print("")


static func _test_read_of_a_trusted_release(testing: Testing) -> void:
	testing.begin("Kept release: a kept manifest the chain still trusts reads back, parsed")
	var assets := _assets(UpdateFixtures.key())
	var update_folder := UpdateFixtures.scratch("kept_read")
	_keep(update_folder, assets, _both())
	var options := _options("read")
	var read := KeptRelease.read(_VERSION, update_folder, options)
	UpdateFixtures.remove(update_folder)
	UpdateFixtures.remove(str(options["trust_store"]))
	testing.eq(read.get("bytes"), assets[ReleaseAssets.manifest_name(_VERSION)],
			"bytes → the kept manifest's text")
	var manifest: Dictionary = read.get("manifest", {})
	testing.eq(manifest.get("error"), "", "manifest → a parse with no error")
	testing.eq(manifest.get("version"), "1.9.0", "for the kept version")
	testing.eq(manifest.get("archive"), "godot-mcp-toolkit-1.9.0.zip", "naming its zip")
	print("")


static func _test_read_of_a_release_that_fails_its_check(testing: Testing) -> void:
	testing.begin("Kept release: a kept manifest that is missing or fails its check reads as none")
	var trusted := _assets(UpdateFixtures.key())
	var manifest_name := ReleaseAssets.manifest_name(_VERSION)
	var signature_name := ReleaseAssets.signature_name(_VERSION)
	# Signed by a listed key, but the manifest names another version.
	var other_version := UpdateFixtures.manifest_text(
			"2.0.0", PackedByteArray([1, 2, 3])).to_utf8_buffer()
	var cases := {
		"nothing kept": {},
		"the signature missing": {manifest_name: trusted[manifest_name]},
		"a signature by an unlisted key": _assets(UpdateFixtures.other_key()),
		"a signature file that is no signature": {manifest_name: trusted[manifest_name],
				signature_name: "not a signature".to_utf8_buffer()},
		"a signed manifest for another version": {manifest_name: other_version,
				signature_name: UpdateFixtures.signature_of(other_version, UpdateFixtures.key())},
	}
	var options := _options("refused")
	var results := {}
	for label: String in cases:
		var update_folder := UpdateFixtures.scratch("kept_refused")
		var kept: Dictionary = cases[label]
		_keep(update_folder, kept, kept.keys())
		results[label] = KeptRelease.read(_VERSION, update_folder, options)
		UpdateFixtures.remove(update_folder)
	UpdateFixtures.remove(str(options["trust_store"]))
	for label: String in cases:
		testing.eq(results[label], {}, "%s → an empty dictionary" % label)
	print("")


static func _test_signature_refused(testing: Testing) -> void:
	testing.begin("Kept release: only a kept pair whose signature the chain refuses reads as refused")
	var trusted := _assets(UpdateFixtures.key())
	var manifest_name := ReleaseAssets.manifest_name(_VERSION)
	var other_version := UpdateFixtures.manifest_text(
			"2.0.0", PackedByteArray([1, 2, 3])).to_utf8_buffer()
	var cases := {
		"nothing kept": [{}, false],
		"the signature missing": [{manifest_name: trusted[manifest_name]}, false],
		"a signature by a listed key": [trusted, false],
		"a signed manifest for another version": [{manifest_name: other_version,
				ReleaseAssets.signature_name(_VERSION):
						UpdateFixtures.signature_of(other_version, UpdateFixtures.key())}, false],
		"a signature by an unlisted key": [_assets(UpdateFixtures.other_key()), true],
	}
	var options := _options("signature_refused")
	var results := {}
	for label: String in cases:
		var update_folder := UpdateFixtures.scratch("kept_signature_refused")
		var kept: Dictionary = (cases[label] as Array)[0]
		_keep(update_folder, kept, kept.keys())
		results[label] = KeptRelease.signature_refused(_VERSION, update_folder, options)
		UpdateFixtures.remove(update_folder)
	UpdateFixtures.remove(str(options["trust_store"]))
	for label: String in cases:
		var refused: bool = (cases[label] as Array)[1]
		testing.eq(results[label], refused,
				"%s → %s" % [label, "refused" if refused else "not refused"])
	print("")
