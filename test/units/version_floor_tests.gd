@tool
extends RefCounted
## Unit tests for the declared-floor helpers in VersionUtils: parse_major_minor, the
## strict version grammar both sides of the handshake share, and floor_verdict, which
## judges a peer's version against a major.minor floor.

const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")


static func run(testing) -> void:
	_test_parse_major_minor(testing)
	_test_floor_verdict(testing)


# A version parses with or without a patch and with a prerelease or build suffix;
# anything else is (-1, -1), never a 0 that would read as "below".
static func _test_parse_major_minor(testing) -> void:
	testing.begin("parse_major_minor — strict major.minor[.patch][-tag|+build]")
	testing.eq(VersionUtils.parse_major_minor("1.0"), Vector2i(1, 0), "major.minor")
	testing.eq(VersionUtils.parse_major_minor("1.2.3"), Vector2i(1, 2), "major.minor.patch")
	testing.eq(VersionUtils.parse_major_minor(" 2.10.0-beta.1 "), Vector2i(2, 10), "trimmed, with a prerelease")
	testing.eq(VersionUtils.parse_major_minor(""), Vector2i(-1, -1), "empty")
	testing.eq(VersionUtils.parse_major_minor("1"), Vector2i(-1, -1), "a bare major")
	testing.eq(VersionUtils.parse_major_minor("1.2.3.4"), Vector2i(-1, -1), "four numeric parts")
	testing.eq(VersionUtils.parse_major_minor("unknown"), Vector2i(-1, -1), "non-numeric")
	print("")


# The patch segment never matters; an unparsable side is "unknown", so the caller
# falls through to its product-version message.
static func _test_floor_verdict(testing) -> void:
	testing.begin("floor_verdict — below, ok, unknown")
	testing.eq(VersionUtils.floor_verdict("1.0.9", "1.1"), "below", "a lower minor is below")
	testing.eq(VersionUtils.floor_verdict("1.1.0", "1.1"), "ok", "equal to the floor")
	testing.eq(VersionUtils.floor_verdict("1.2.0", "1.1"), "ok", "a higher minor")
	testing.eq(VersionUtils.floor_verdict("2.0.0", "1.5"), "ok", "a higher major beats a higher floor minor")
	testing.eq(VersionUtils.floor_verdict("", "1.0"), "unknown", "a missing version")
	testing.eq(VersionUtils.floor_verdict("dev", "1.0"), "unknown", "a malformed version")
	testing.eq(VersionUtils.floor_verdict("1.0.4", "x.y"), "unknown", "a malformed floor")
	print("")
