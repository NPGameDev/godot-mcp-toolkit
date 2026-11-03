@tool
extends RefCounted
## The update manifest a release publishes: its strict reading and the engine check.
##
## The manifest names the release's zip, its size and SHA-256, and the oldest Godot
## the release runs on. Its signature is checked before it is read (see
## [code]release_signature.gd[/code]), so a manifest that reads here is one the
## maintainer published, and the zip it pins can be trusted byte for byte.[br]
## [br]
## Shape: [code]{"format": 1, "version": "X.Y.Z", "archive": "godot-mcp-toolkit-X.Y.Z.zip",
## "archive_size": N, "archive_sha256": "<64 hex>", "min_godot": "4.2",
## "compatible_server": "X.Y.Z", "expires_at": N}[/code]. [code]expires_at[/code] is a Unix
## time.[br]
## [br]
## The last two inform and never refuse, so a release with neither, or with one this reader
## cannot read, still installs. An older toolkit reads a later manifest's additions the same
## way: a key it does not know is ignored.

# Direct preloads: core/modules.gd does not list this folder's scripts.
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const ReleaseAssets := preload("res://addons/godot_mcp_toolkit/self_update/release_assets.gd")
const ContentHash := preload("res://addons/godot_mcp_toolkit/self_update/content_hash.gd")

## The manifest format this toolkit reads.
const FORMAT := 1

## The largest manifest read, in bytes.
const MAX_BYTES := 64 * 1024

## The largest zip a manifest may name, in bytes: well above the toolkit's size, low
## enough that a wrong value cannot fill a disk.
const MAX_ARCHIVE_BYTES := 64 * 1024 * 1024

const _KEY_FORMAT := "format"
const _KEY_VERSION := "version"
const _KEY_ARCHIVE := "archive"
const _KEY_ARCHIVE_SIZE := "archive_size"
const _KEY_ARCHIVE_SHA256 := "archive_sha256"
const _KEY_MIN_GODOT := "min_godot"
const _KEY_COMPATIBLE_SERVER := "compatible_server"
const _KEY_EXPIRES_AT := "expires_at"


## Reads the manifest [param text] for the release [param expected_version].
##
## Returns a dictionary whose [code]error[/code] is empty when the manifest holds,
## with [code]version[/code], [code]archive[/code], [code]archive_size[/code] (int),
## [code]archive_sha256[/code] and [code]min_godot[/code], plus
## [code]compatible_server[/code] (a stable [code]X.Y.Z[/code]) and
## [code]expires_at[/code] (int) when the manifest holds them in that form; each key is
## left out otherwise. When the manifest does not hold, [code]error[/code] names the first
## rule broken and no other key is set.
static func parse(text: String, expected_version: String) -> Dictionary:
	if text.length() > MAX_BYTES:
		return _failure("the manifest is larger than %d bytes" % MAX_BYTES)
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("the manifest is not a JSON object")
	var data: Dictionary = json.data
	var format: Variant = data.get(_KEY_FORMAT, null)
	if not _is_whole_number(format) or int(format) != FORMAT:
		return _failure("the manifest format is not %d" % FORMAT)

	var wanted := UpdateCheck.parse_version(expected_version)
	var version: Variant = data.get(_KEY_VERSION, null)
	if wanted.is_empty() or not version is String or UpdateCheck.parse_version(str(version)) != wanted:
		return _failure("the manifest is not for version %s" % expected_version)
	var normalized := "%d.%d.%d" % [wanted[0], wanted[1], wanted[2]]

	var archive: Variant = data.get(_KEY_ARCHIVE, null)
	if not archive is String or str(archive) != ReleaseAssets.archive_name(normalized):
		return _failure("the manifest names another archive")
	var size: Variant = data.get(_KEY_ARCHIVE_SIZE, null)
	if not _is_whole_number(size) or int(size) <= 0 or int(size) > MAX_ARCHIVE_BYTES:
		return _failure("the manifest's archive size is not a size")
	var digest: Variant = data.get(_KEY_ARCHIVE_SHA256, null)
	if not digest is String or not ContentHash.is_hex_digest(str(digest)):
		return _failure("the manifest's archive hash is not a SHA-256")
	var min_godot: Variant = data.get(_KEY_MIN_GODOT, null)
	if not min_godot is String or VersionUtils.parse_major_minor(str(min_godot)).x < 0:
		return _failure("the manifest's Godot floor is not a version")

	var manifest := {
		"error": "",
		_KEY_VERSION: normalized,
		_KEY_ARCHIVE: str(archive),
		_KEY_ARCHIVE_SIZE: int(size),
		_KEY_ARCHIVE_SHA256: str(digest),
		_KEY_MIN_GODOT: str(min_godot),
	}
	var compatible_server: Variant = data.get(_KEY_COMPATIBLE_SERVER, null)
	if compatible_server is String:
		var server_parts := UpdateCheck.parse_version(str(compatible_server))
		if not server_parts.is_empty():
			manifest[_KEY_COMPATIBLE_SERVER] = "%d.%d.%d" % [server_parts[0], server_parts[1], server_parts[2]]
	var expires_at: Variant = data.get(_KEY_EXPIRES_AT, null)
	if _is_whole_number(expires_at):
		manifest[_KEY_EXPIRES_AT] = int(expires_at)
	return manifest


## Whether the release a [method parse] result describes runs on the engine whose
## [code]major.minor[/code] is [param engine_version].
static func supports_engine(manifest: Dictionary, engine_version: String) -> bool:
	return VersionUtils.is_at_least(engine_version, str(manifest.get(_KEY_MIN_GODOT, "")))


static func _failure(reason: String) -> Dictionary:
	return {"error": reason}


# JSON numbers arrive as floats; a size or a format must be a whole one.
static func _is_whole_number(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_equal_approx(float(value), roundf(float(value)))
