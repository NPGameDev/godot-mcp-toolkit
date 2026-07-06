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
const NodeManageTests := preload("res://test/units/node_manage_tests.gd")
const UndoRedoTests := preload("res://test/units/undo_redo_tests.gd")
const ErrorContractTests := preload("res://test/units/error_contract_tests.gd")
const PathsVersioningTests := preload("res://test/units/paths_versioning_tests.gd")
const ProceduralAssetTests := preload("res://test/units/procedural_asset_tests.gd")
const TextInputTests := preload("res://test/units/text_input_tests.gd")
const SerializeIoTests := preload("res://test/units/serialize_io_tests.gd")
const AutoloadHealTests := preload("res://test/units/autoload_heal_tests.gd")
const PortConfigTests := preload("res://test/units/port_config_tests.gd")
const McpJsonBuildTests := preload("res://test/units/mcp_json_build_tests.gd")
const MacosLaunchHintTests := preload("res://test/units/macos_launch_hint_tests.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")


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
	NodeManageTests.run(testing)
	UndoRedoTests.run(testing)
	await ErrorContractTests.run(testing)  # M10 holds group 40 (response-validation) await → coroutine
	PathsVersioningTests.run(testing)
	ProceduralAssetTests.run(testing)
	TextInputTests.run(testing)
	SerializeIoTests.run(testing)
	AutoloadHealTests.run(testing)
	PortConfigTests.run(testing)
	McpJsonBuildTests.run(testing)
	MacosLaunchHintTests.run(testing)
	_test_published_token_path(testing)

	var failed := testing.report()
	quit(0 if failed == 0 else 1)


# Pins that the REGISTRY-PUBLISH token path tracks a relocated user:// dir.
# globalize_path("user://…") reads application/config/use_custom_user_dir live, so
# the published absolute path follows a custom user dir instead of the default
# app_userdata location, which is what lets such projects authenticate. GDScript
# has no try/finally, so the relocated setting is restored BEFORE any check runs:
# a failure can never leave the project settings dirty.
func _test_published_token_path(testing: Testing) -> void:
	testing.begin("Published token path honors use_custom_user_dir")
	# Variant source (ProjectSettings.get_setting) → explicit coercion, not inference.
	var prev_use: bool = bool(ProjectSettings.get_setting("application/config/use_custom_user_dir", false))
	var prev_name: String = str(ProjectSettings.get_setting("application/config/custom_user_dir_name", ""))

	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", "godot_mcp_toolkit_unit_test")

	var published: String = MCPAuth.get_published_token_path()

	ProjectSettings.set_setting("application/config/use_custom_user_dir", prev_use)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", prev_name)

	testing.ok(published.contains("godot_mcp_toolkit_unit_test"), "relocated user dir honored at publish")
	testing.ok(published.begins_with("/") or published.substr(1, 2) == ":/", "absolute path (POSIX or Windows drive)")
	testing.ok(published.contains("project_instance_"), "per-instance segment present")
	testing.ok(published.ends_with("/mcp_token"), "token filename suffix")
	print("")


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
