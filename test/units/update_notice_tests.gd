@tool
extends RefCounted
## Unit tests for the notice the dock badge shows after an apply: the keys and values each of
## update_notice.gd's builders gives for an installed release, a failed one, and a staged one the
## exit will not install, and when an installed release changes the server it is tested with.

const Testing := preload("res://test/units/testing.gd")
const UpdateNotice := preload("res://addons/godot_mcp_toolkit/self_update/update_notice.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")

# A server version other than the one this toolkit is tested with.
const _OTHER_SERVER := "0.9.0"


static func run(testing: Testing) -> void:
	_test_settle_of_an_installed_release(testing)
	_test_settle_of_a_failed_release(testing)
	_test_not_installed(testing)


# What UpdateSettler.settle returns, as far as a notice reads it.
static func _settled(compatible_server: String, reason: String) -> Dictionary:
	return {"report": "", "from": "1.1.0", "to": "1.9.0", "reason": reason, "attempts": 1,
			"compatible_server": compatible_server}


static func _test_settle_of_an_installed_release(testing: Testing) -> void:
	testing.begin("Update notice: an installed release reports its versions and whether its server "
			+ "changed")
	testing.eq(UpdateNotice.of_settle(_settled(VersionUtils.COMPATIBLE_SERVER_VERSION, ""), true), {
		"kind": "updated",
		"version": "1.9.0",
		"from_version": "1.1.0",
		"reason": "",
		"server_changed": false,
	}, "staged with the server this toolkit is tested with → updated, server unchanged")
	testing.eq(UpdateNotice.of_settle(_settled(_OTHER_SERVER, ""), true), {
		"kind": "updated",
		"version": "1.9.0",
		"from_version": "1.1.0",
		"reason": "",
		"server_changed": true,
	}, "staged with another server → updated, server changed")
	print("")


static func _test_settle_of_a_failed_release(testing: Testing) -> void:
	testing.begin("Update notice: a failed apply reports why, and never a server change")
	testing.eq(UpdateNotice.of_settle(_settled(_OTHER_SERVER, "a file was locked"), false), {
		"kind": "failed",
		"version": "1.9.0",
		"from_version": "1.1.0",
		"reason": "a file was locked",
		"server_changed": false,
	}, "failed, staged with another server → failed with its reason, server unchanged")
	print("")


static func _test_not_installed(testing: Testing) -> void:
	testing.begin("Update notice: a staged release the exit will not install reports as failed")
	testing.eq(UpdateNotice.not_installed("1.9.0", "1.1.0", "the release's key was dropped"), {
		"kind": "failed",
		"version": "1.9.0",
		"from_version": "1.1.0",
		"reason": "the release's key was dropped",
		"server_changed": false,
	}, "not installed → failed with the staged and installed versions and the reason")
	print("")
