@tool
extends RefCounted
## Unit tests for the update manifest's strict reading and its engine check: a valid
## manifest, each field missing or malformed, a manifest for another version, the
## size limits, and the Godot floor at and past the running engine.

const ReleaseManifest := preload("res://addons/godot_mcp_toolkit/update/release_manifest.gd")

const _DIGEST := "3370a7ff44d61ecd5519ab44ccd866d68644c4b099de1e85e5fad913dbdd12f8"


static func run(testing) -> void:
	_test_valid(testing)
	_test_field_rules(testing)
	_test_version_match(testing)
	_test_size_limits(testing)
	_test_engine_floor(testing)


static func _manifest(overrides: Dictionary = {}) -> Dictionary:
	var data := {
		"format": 1,
		"version": "1.2.0",
		"archive": "godot-mcp-toolkit-1.2.0.zip",
		"archive_size": 734482,
		"archive_sha256": _DIGEST,
		"min_godot": "4.2",
	}
	for key: String in overrides:
		if overrides[key] == null:
			data.erase(key)
		else:
			data[key] = overrides[key]
	return data


static func _error(overrides: Dictionary, version: String = "1.2.0") -> String:
	return str(ReleaseManifest.parse(JSON.stringify(_manifest(overrides)), version)["error"])


static func _test_valid(testing) -> void:
	testing.begin("Release manifest: a valid manifest reads")
	testing.eq(ReleaseManifest.parse(JSON.stringify(_manifest()), "1.2.0"), {
		"error": "",
		"version": "1.2.0",
		"archive": "godot-mcp-toolkit-1.2.0.zip",
		"archive_size": 734482,
		"archive_sha256": _DIGEST,
		"min_godot": "4.2",
	}, "every field, the size as an int")
	print("")


static func _test_field_rules(testing) -> void:
	testing.begin("Release manifest: each field's rule")
	testing.eq(str(ReleaseManifest.parse("[1]", "1.2.0")["error"]), "the manifest is not a JSON object", "a JSON array → refused")
	testing.eq(str(ReleaseManifest.parse("{", "1.2.0")["error"]), "the manifest is not a JSON object", "broken JSON → refused")
	testing.eq(_error({"format": 2}), "the manifest format is not 1", "format 2 → refused")
	testing.eq(_error({"format": null}), "the manifest format is not 1", "no format → refused")
	testing.eq(_error({"format": 1.5}), "the manifest format is not 1", "a fractional format → refused")
	testing.eq(_error({"archive": "other.zip"}), "the manifest names another archive", "another archive name → refused")
	testing.eq(_error({"archive_size": 0}), "the manifest's archive size is not a size", "size 0 → refused")
	testing.eq(_error({"archive_size": "734482"}), "the manifest's archive size is not a size", "a size as text → refused")
	testing.eq(_error({"archive_sha256": _DIGEST.to_upper()}), "the manifest's archive hash is not a SHA-256", "an uppercase hash → refused")
	testing.eq(_error({"archive_sha256": null}), "the manifest's archive hash is not a SHA-256", "no hash → refused")
	testing.eq(_error({"min_godot": "four"}), "the manifest's Godot floor is not a version", "a floor in words → refused")
	testing.eq(_error({"min_godot": 4.2}), "the manifest's Godot floor is not a version", "a floor as a number → refused")
	print("")


static func _test_version_match(testing) -> void:
	testing.begin("Release manifest: only the version asked for")
	testing.eq(_error({"version": "1.2.1"}), "the manifest is not for version 1.2.0", "another version → refused")
	testing.eq(_error({"version": "1.2.0-beta"}), "the manifest is not for version 1.2.0", "a prerelease → refused")
	testing.eq(_error({}, "v1.2.0"), "", "a v-prefixed version asked for → the same version")
	testing.eq(_error({}, "nonsense"), "the manifest is not for version nonsense", "an unreadable version asked for → refused")
	print("")


static func _test_size_limits(testing) -> void:
	testing.begin("Release manifest: size limits")
	testing.eq(_error({"archive_size": 64 * 1024 * 1024}), "", "an archive at the 64 MiB limit → reads")
	testing.eq(_error({"archive_size": 64 * 1024 * 1024 + 1}), "the manifest's archive size is not a size",
			"an archive one byte past the limit → refused")
	var padded := JSON.stringify(_manifest()) + " ".repeat(64 * 1024)
	testing.eq(str(ReleaseManifest.parse(padded, "1.2.0")["error"]), "the manifest is larger than 65536 bytes",
			"a manifest past 64 KiB → refused")
	print("")


static func _test_engine_floor(testing) -> void:
	testing.begin("Release manifest: the Godot floor")
	var manifest := ReleaseManifest.parse(JSON.stringify(_manifest({"min_godot": "4.4"})), "1.2.0")
	testing.ok(ReleaseManifest.supports_engine(manifest, "4.4"), "an engine at the floor → supported")
	testing.ok(ReleaseManifest.supports_engine(manifest, "4.7"), "a newer engine → supported")
	testing.ok(not ReleaseManifest.supports_engine(manifest, "4.3"), "an engine one minor below → not supported")
	testing.ok(ReleaseManifest.supports_engine(manifest, "5.0"), "a newer major → supported")
	print("")
