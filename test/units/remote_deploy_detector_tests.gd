@tool
extends RefCounted
## Pins which export flags the remote-deploy detector reads as a one-click deploy with
## remote debug: those carrying the remote-debug flag. Calls its static predicate,
## since the headless runner cannot instantiate an EditorExportPlugin. The
## _export_begin call that reports a deploy to the debug-session tracker is not
## covered by the sweep yet; GAP in SWEEP-COVERAGE-MANIFEST.md (`debugger.get_log`).

const Testing := preload("res://test/units/testing.gd")
const RemoteDeployDetector := preload("res://addons/godot_mcp_toolkit/core/remote_deploy_detector.gd")


static func run(testing: Testing) -> void:
	_test_remote_debug_flag_marks_deploy(testing)


static func _test_remote_debug_flag_marks_deploy(testing: Testing) -> void:
	testing.begin("remote-deploy detector reads only the remote-debug flag as a deploy")
	testing.eq(RemoteDeployDetector.is_remote_debug_deploy(2), true,
			"export flags with remote debug (2) → a deploy")
	testing.eq(RemoteDeployDetector.is_remote_debug_deploy(26), true,
			"export flags with remote debug, collisions and navigation (26) → a deploy")
	testing.eq(RemoteDeployDetector.is_remote_debug_deploy(0), false,
			"a manual export's flags (0) → not a deploy")
	testing.eq(RemoteDeployDetector.is_remote_debug_deploy(29), false,
			"export flags with every flag but remote debug (29) → not a deploy")
	print("")
