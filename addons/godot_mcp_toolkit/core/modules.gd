@tool
extends RefCounted
## Centralized preloads for plugin-internal scripts.
##
## The preload aggregator: reach a script listed here through its constant, not its
## path. Two kinds of script preload directly instead: one this file preloads, which
## cannot preload it back (a cycle), and one in the runtime autoload's preload closure,
## which must not pull in the editor-only scripts listed here. When a file moves, update
## its constant here and every other file that names its path, in code, scenes, tests
## or docs: a preload, a [code]load()[/code] call, a path string or an [code]ext_resource[/code].
## MCPToolkitError has class_name and needs no preload.

const Coerce := preload("res://addons/godot_mcp_toolkit/contract/coerce.gd")
const DeclaredTypeFitter := preload("res://addons/godot_mcp_toolkit/contract/declared_type_fitter.gd")
const ExecuteHints := preload("res://addons/godot_mcp_toolkit/contract/execute_hints.gd")
const Pagination := preload("res://addons/godot_mcp_toolkit/contract/pagination.gd")
const PropertySetCheck := preload("res://addons/godot_mcp_toolkit/contract/property_set_check.gd")
const ScreenshotResponse := preload("res://addons/godot_mcp_toolkit/contract/screenshot_response.gd")
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const Untrusted := preload("res://addons/godot_mcp_toolkit/security/untrusted.gd")
const Scrubber := preload("res://addons/godot_mcp_toolkit/security/scrubber.gd")
const Audit := preload("res://addons/godot_mcp_toolkit/security/audit.gd")
const MCPJsonSync := preload("res://addons/godot_mcp_toolkit/ui/mcp_json_sync.gd")
const ServerPinPolicy := preload("res://addons/godot_mcp_toolkit/ui/mcp_json/server_pin_policy.gd")
const DockThemeOverride := preload("res://addons/godot_mcp_toolkit/ui/dock/dock_theme_override.gd")
const ExtensionCatalogFetcher := preload("res://addons/godot_mcp_toolkit/ui/dock/ext/extension_catalog_fetcher.gd")
const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const ProjectPaths := preload("res://addons/godot_mcp_toolkit/paths/project_paths.gd")
const UserPathMonitor := preload("res://addons/godot_mcp_toolkit/paths/user_path_monitor.gd")
const LogBuffer := preload("res://addons/godot_mcp_toolkit/logging/log_buffer.gd")
const CommandHelpers := preload("res://addons/godot_mcp_toolkit/commands/editor_helpers.gd")
const LogHelpers := preload("res://addons/godot_mcp_toolkit/logging/log_helpers.gd")
const NodejsCheck := preload("res://addons/godot_mcp_toolkit/versioning/nodejs_check.gd")
const VersionUtils := preload("res://addons/godot_mcp_toolkit/versioning/mcp_version_utils.gd")
const StaleInstanceHint := preload("res://addons/godot_mcp_toolkit/versioning/stale_instance_hint.gd")
const UpdateCheck := preload("res://addons/godot_mcp_toolkit/versioning/update_check.gd")
const UpdateCheckRunner := preload("res://addons/godot_mcp_toolkit/versioning/update_check_runner.gd")
const SetupSteps := preload("res://addons/godot_mcp_toolkit/core/setup_steps.gd")
const SetupStepTracker := preload("res://addons/godot_mcp_toolkit/core/setup_step_tracker.gd")
const Consent := preload("res://addons/godot_mcp_toolkit/core/consent.gd")
const EditorAccess := preload("res://addons/godot_mcp_toolkit/core/editor_access.gd")
const ResponseLimits := preload("res://addons/godot_mcp_toolkit/core/response_limits.gd")
const GDScriptSource := preload("res://addons/godot_mcp_toolkit/core/gdscript_source.gd")
const ScriptReload := preload("res://addons/godot_mcp_toolkit/core/script_reload.gd")
const RuntimeOptOut := preload("res://addons/godot_mcp_toolkit/runtime/runtime_opt_out.gd")
