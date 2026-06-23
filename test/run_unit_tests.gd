extends SceneTree
## Headless unit test runner for MCP Toolkit pure-logic internals.
##
## Run: timeout 30 godot --headless --script test/run_unit_tests.gd
##
## Exit code: 0 = all passed, 1 = failures detected.
## The final banner is always printed for environments where exit codes
## are unreliable (Windows Godot).

const Testing := preload("res://test/units/testing.gd")
const SecurityTests := preload("res://test/units/security_tests.gd")
const RegistryCommandTests := preload("res://test/units/registry_command_tests.gd")
const RegistryStoreTests := preload("res://test/units/registry_store_tests.gd")
const ExtensionMetaTests := preload("res://test/units/extension_meta_tests.gd")
const OptionsTests := preload("res://test/units/options_tests.gd")
const DispatchLaneTests := preload("res://test/units/dispatch_lane_tests.gd")
const SignalResolverTests := preload("res://test/units/signal_resolver_tests.gd")
const SceneOpsTests := preload("res://test/units/scene_ops_tests.gd")
const PropertyEditTests := preload("res://test/units/property_edit_tests.gd")
const UndoRedoTests := preload("res://test/units/undo_redo_tests.gd")
const ErrorContractTests := preload("res://test/units/error_contract_tests.gd")
const PathsVersioningTests := preload("res://test/units/paths_versioning_tests.gd")
const ProceduralAssetTests := preload("res://test/units/procedural_asset_tests.gd")
const SerializeIoTests := preload("res://test/units/serialize_io_tests.gd")


func _init() -> void:
	print("=== MCP Toolkit Unit Tests ===")
	print("")

	if not _guard_addon_classes():
		quit(1)
		return

	var testing := Testing.new()
	SecurityTests.run(testing)
	RegistryCommandTests.run(testing)
	RegistryStoreTests.run(testing)
	await ExtensionMetaTests.run(testing)  # M3 holds group 6 (path-guard) await → coroutine
	OptionsTests.run(testing)
	DispatchLaneTests.run(testing)
	SignalResolverTests.run(testing)
	SceneOpsTests.run(testing)
	PropertyEditTests.run(testing)
	UndoRedoTests.run(testing)
	await ErrorContractTests.run(testing)  # M10 holds group 40 (response-validation) await → coroutine
	PathsVersioningTests.run(testing)
	ProceduralAssetTests.run(testing)
	SerializeIoTests.run(testing)

	var failed := testing.report()
	quit(0 if failed == 0 else 1)


# --- Guards ----------------------------------------------------------------

func _guard_addon_classes() -> bool:
	# If any class_name is unavailable (addon not enabled), Godot throws a
	# parse error before _init() runs. This runtime check is defence-in-depth
	# for unexpected constructor failures.
	var registry := MCPToolkitCommandRegistry.new()
	var options := MCPToolkitCommandOptions.new()
	var extension_options := MCPToolkitExtensionOptions.new("guard")
	var tool_context := MCPToolkitToolContext.new()
	if registry == null or options == null or extension_options == null or tool_context == null:
		print("FAIL: addon classes not accessible — is the addon enabled in project.godot?")
		return false
	print("Guard: all 4 addon classes accessible")
	print("")
	return true
