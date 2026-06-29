@tool
extends RefCounted
## The plugin's composition root — constructs and wires the collaborator graph,
## then tears it down in reverse.
##
## compose() builds the whole object graph (registry, server, debug bridge,
## command registrar, extensions, export plugin, log buffer, user-path monitor,
## registry registration, playtest watcher, dock) and returns the owning Handle.
## The orchestrator (plugin.gd) calls compose() once from _enter_tree, holds the
## Handle, drives it (poll_playtest each _process), and calls Handle.dispose()
## once from _exit_tree. This owns wiring, not lifecycle phases: the phase
## ordering, version-warn, and onboarding stay in the orchestrator. The
## registry-registration policy (initial register + jittered re-verify, and the
## runtime-preserving re-publish on token rotation) is folded in here as two
## private steps — it is construction-time wiring.
##
## Editor-only: names EditorInterface / the EditorPlugin host, so it is preloaded
## only by the editor-only plugin.gd and never reached by the runtime autoload.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const RegistryClient = Modules.RegistryClient
const MCPServer := preload("res://addons/godot_mcp_toolkit/transport/mcp_server.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")
const ExtensionLoader := preload("res://addons/godot_mcp_toolkit/extensions/extension_loader.gd")
const BuiltinCommandRegistration := preload("res://addons/godot_mcp_toolkit/transport/builtin_command_registration.gd")
const PlaytestEndDetector := preload("res://addons/godot_mcp_toolkit/core/playtest_end_detector.gd")
const DebugBridge := preload("res://addons/godot_mcp_toolkit/transport/debug_bridge.gd")
# Teardown counterpart of PlaytestCommands.register(..., debug_bridge): dispose()
# calls PlaytestCommands.clear_debug_bridge() as the I12 reverse of that register.
const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_commands.gd")


## Composes the plugin's collaborator graph and returns the owning Handle.
## on_user_path_changed is the orchestrator's own handler for the user-path
## monitor's signal — injected so the handler stays on the orchestrator without
## the composer poking a plugin private.
static func compose(plugin: EditorPlugin, on_user_path_changed: Callable) -> Handle:
	var handle := Handle.new()
	handle._plugin = plugin

	var registry := MCPToolkitCommandRegistry.new()
	var server := MCPServer.new()
	server.name = "MCPServer"
	server.set_registry(registry)
	server.editor_plugin = plugin

	# Debugger bridge — create early so command registrars can reference it.
	var debug_bridge := DebugBridge.new()
	plugin.add_debugger_plugin(debug_bridge)

	BuiltinCommandRegistration.register_all(registry, server, debug_bridge)

	# Third-party extensions — profile-exempt, always loaded.
	ExtensionLoader.load_all(registry, server)
	# Live hot-reload: watch EditorFileSystem for extension additions/removals.
	var extension_watcher := ExtensionLoader.start_watcher(registry, server)

	var export_plugin := preload("res://addons/godot_mcp_toolkit/core/export_strip.gd").new()
	plugin.add_export_plugin(export_plugin)

	Modules.LogBuffer.setup()

	# Monitor the ProjectSettings that shift user:// paths (config/name,
	# use_custom_user_dir, custom_user_dir_name). Each consumer connects
	# directly and handles its own recovery.
	var user_path_monitor = Modules.UserPathMonitor.new()
	user_path_monitor.start()
	user_path_monitor.user_path_changed.connect(on_user_path_changed)

	# Edge-detects the play→stop transition; polled each _process.
	var playtest_end_detector := PlaytestEndDetector.new(server)

	plugin.add_child(server)
	server.bind_user_path_monitor(user_path_monitor)
	# After a user-path change the server re-writes its token and announces the new
	# path; we re-publish the registry entry runtime-preservingly (ensure_registered,
	# not register) so a game running across the rename keeps Mode-B discovery.
	server.token_rewritten.connect(func(token_path: String): _republish_on_token_rewrite(server, token_path))
	server.start()

	# Register in the system-wide project registry so the TS bridge can
	# discover us by project path. Must come after start() — port unknown
	# until _scan_and_listen() runs.
	_register_in_registry(server)

	# -- Bottom-panel dock --
	var dock: Control = preload("res://addons/godot_mcp_toolkit/ui/dock/dock.tscn").instantiate()
	dock.bind(server, Modules.Audit.get_log_path())
	plugin.add_control_to_bottom_panel(dock, "MCP Toolkit")

	handle._server = server
	handle._export_plugin = export_plugin
	handle._dock = dock
	handle._extension_watcher = extension_watcher
	handle._debug_bridge = debug_bridge
	handle._user_path_monitor = user_path_monitor
	handle._playtest_end_detector = playtest_end_detector
	return handle


# Register this editor in the system-wide project registry. The initial register()
# plus a jittered deferred ensure_registered() re-verify (concurrent editors may
# clobber our entry after our initial verify passes). Re-resolve the LSP endpoint
# at fire time so a mid-window Q4 change isn't reverted.
static func _register_in_registry(server: Node) -> void:
	var bound_port: int = server.get_bound_port()
	if bound_port > 0:
		var lsp := MCPServer.resolve_lsp_endpoint()
		RegistryClient.register(bound_port, MCPAuth.get_published_token_path(), lsp["host"], lsp["port"])
		# Deferred re-verify: concurrent editors may clobber our entry after
		# our initial verify passes. Jittered delay ensures all editors have
		# finished their initial registration before we re-check. Re-resolve the
		# LSP endpoint at fire time so a mid-window Q4 change isn't reverted.
		var _jitter := randf_range(5.0, 10.0)
		server.get_tree().create_timer(_jitter).timeout.connect(
			func():
				var lsp_re := MCPServer.resolve_lsp_endpoint()
				RegistryClient.ensure_registered(bound_port, MCPAuth.get_published_token_path(), lsp_re["host"], lsp_re["port"]))


# Re-publish this editor's registry entry after the server re-writes its token to
# a new user:// path. ensure_registered (not register) so an active playtest's
# runtime_port/runtime_pid are preserved — otherwise Mode-B (running-game)
# discovery dies for the rest of the session. Re-resolve the LSP endpoint at fire
# time, mirroring the startup registration, so a concurrent endpoint change isn't
# reverted to a stale value.
static func _republish_on_token_rewrite(server: Node, token_path: String) -> void:
	if server == null:
		return
	var bound_port: int = server.get_bound_port()
	if bound_port <= 0:
		return
	var lsp := MCPServer.resolve_lsp_endpoint()
	# The signal carries the rewritten path in user:// form; publish it in the
	# absolute form the out-of-engine server opens (see MCPAuth.get_published_token_path).
	RegistryClient.ensure_registered(
		bound_port, ProjectSettings.globalize_path(token_path), lsp["host"], lsp["port"]
	)


## Owns the collaborator graph compose() built and disposes it in reverse.
##
## The orchestrator reaches the two collaborators it still needs post-compose via
## server() (menu, watcher wiring) and dock() (menu, onboarding wizard); the
## other five instances stay private and are touched only by dispose(). poll_playtest()
## drives the playtest watcher each _process; dispose() tears the graph down in the
## exact reverse order of compose() (behavior-critical — see GodotCodeStandards §8/§10.5).
class Handle:
	extends RefCounted

	const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
	const RegistryClient = Modules.RegistryClient
	const PlaytestCommands := preload("res://addons/godot_mcp_toolkit/commands/playtest/playtest_commands.gd")
	const PlaytestEndDetector := preload("res://addons/godot_mcp_toolkit/core/playtest_end_detector.gd")

	var _plugin: EditorPlugin = null
	var _server: Node = null
	var _export_plugin: EditorExportPlugin = null
	var _dock: Control = null
	var _extension_watcher: RefCounted = null  # Live hot-reload watcher (ExtensionLoader)
	var _debug_bridge: RefCounted = null  # EditorDebuggerPlugin for debug.* commands
	var _user_path_monitor = null  # UserPathMonitor — detects config/name changes
	var _playtest_end_detector: PlaytestEndDetector = null  # Edge-detects the play→stop transition

	## The MCP server node (orchestrator passes it to the tool menu).
	func server() -> Node:
		return _server

	## The bottom-panel dock (orchestrator passes it to the tool menu + onboarding wizard).
	func dock() -> Control:
		return _dock

	## Edge-detect the playtest end. Called by the orchestrator's _process.
	func poll_playtest() -> void:
		if _playtest_end_detector != null:
			_playtest_end_detector.poll()

	## Tear down the composed graph in reverse construction order. Behavior-critical
	## ordering — dock → user-path monitor → playtest watcher → extension watcher →
	## debug bridge → export plugin → server+registry.
	func dispose() -> void:
		# Dock — remove from panel, then free() immediately (not queue_free())
		# so its script preload chain is released before ObjectDB's exit-time
		# leak check runs.
		if _dock != null:
			_plugin.remove_control_from_bottom_panel(_dock)
			_dock.free()
			_dock = null

		# RefCounted subsystems — drop our references so they can be collected
		# once the dock (which also holds them) is freed above.
		if _user_path_monitor != null:
			_user_path_monitor.stop()
			_user_path_monitor = null

		# Playtest end detector (RefCounted — just null) — drop before server teardown
		# since it holds a server reference.
		_playtest_end_detector = null

		# Extension watcher — disconnect global signals, then drop before server
		# teardown (holds registry ref). Without explicit disconnect, the
		# filesystem_changed / settings_changed handlers become zombie callbacks.
		if _extension_watcher != null:
			var efs := EditorInterface.get_resource_filesystem()
			if efs.filesystem_changed.is_connected(_extension_watcher.on_filesystem_changed):
				efs.filesystem_changed.disconnect(_extension_watcher.on_filesystem_changed)
			if ProjectSettings.settings_changed.is_connected(_extension_watcher.on_settings_changed):
				ProjectSettings.settings_changed.disconnect(_extension_watcher.on_settings_changed)
		_extension_watcher = null

		# Debugger bridge — unregister before server teardown (I12 symmetry).
		PlaytestCommands.clear_debug_bridge()
		if _debug_bridge != null:
			_debug_bridge.cleanup()
			_plugin.remove_debugger_plugin(_debug_bridge)
			_debug_bridge = null

		# Export plugin (RefCounted — do NOT queue_free, just null).
		if _export_plugin != null:
			_plugin.remove_export_plugin(_export_plugin)
			_export_plugin = null

		# Server + registry — clear command registry first to break the
		# Callable → GDScript reference chains, then free() immediately.
		# queue_free() alone causes "resources still in use at exit" because
		# deferred deletion runs after ObjectDB's leak check.
		if _server != null:
			_server.stop()
			_server.clear_registry()
			RegistryClient.deregister()
			_server.free()
			_server = null
