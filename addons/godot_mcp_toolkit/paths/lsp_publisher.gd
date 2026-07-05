@tool
extends RefCounted
## Resolves THIS editor's GDScript-LSP endpoint, publishes it to the registry, and
## re-publishes on a debounced settings change — plus holds the server-reported LSP
## liveness mirror the dock renders.
##
## The editor can't read its own LSP bind status, so there are two halves of one
## "LSP verdict" concern. (1) OUTBOUND: resolve the endpoint THIS editor's setting
## points at (network/language_server/remote_host/port, default 127.0.0.1:6005) and
## publish lsp_host/lsp_port into the registry entry; EditorSettings.settings_changed
## fires globally, so the watch debounces by comparing the re-resolved endpoint
## against the last published one (live re-publish on change). (2) INBOUND: the MCP
## server reports the authoritative verdict via set_reported_lsp_status (it can do
## reliable cross-process liveness the editor cannot); the dock renders whatever was
## last reported and refreshes exactly on change.
##
## Editor-side ONLY — and TAINTED by design: resolve_lsp_endpoint() and the watch
## name EditorInterface directly (they read network/language_server/* and connect to
## EditorSettings.settings_changed). That is allowed because the Mode-B runtime
## autoload has NO LSP publishing (it publishes runtime_port, not an LSP endpoint)
## and must NEVER preload this file. #91713 therefore does not gate this child, but a
## runtime reference to it WOULD taint the autoload, so keep it strictly editor-only:
## only mcp_server.gd (the editor server) preloads it. The orchestrator owns the
## cross-subsystem TRIGGER points (start() → resolve + publish + connect-watch;
## stop() → disconnect-watch; server reports status → set_reported_lsp_status); this
## child owns only the MECHANISM behind each, and the lsp_status_changed SIGNAL stays
## on the orchestrator (the dock binds it there) — this child reports a change via the
## injected status-changed handler so the orchestrator re-emits.
##
## resolve_lsp_endpoint() stays a static EditorInterface reader (verbatim from the
## server, where plugin.gd + the registry callers call it statically): it passes the
## resolved host/port VALUES into RegistryClient.register / ensure_registered, so
## registry_client.gd stays editor-clean for the Mode-B runtime autoload (it never
## resolves the endpoint itself — see registry_client.gd::_build_entry). Unlike the
## sibling tainted children (scene_lease / unfocused), this one does NOT take an
## injected EditorSettings accessor: an injected accessor would force the static
## resolver to become an instance method and break that static call graph for no
## taint gain (the file is never runtime-preloaded), so the lower-risk choice is to
## name EditorInterface directly.

const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const MCPAuth := preload("res://addons/godot_mcp_toolkit/security/auth.gd")

# Last LSP endpoint published to the registry — the re-publish baseline. The watch
# compares the re-resolved endpoint against these to debounce unrelated setting churn.
var _last_lsp_host: String = ""
var _last_lsp_port: int = -1
# Authoritative LSP verdict the MCP server last reported (editor.set_lsp_status). The
# editor can't read its own LSP bind status, so the server tells us and the dock
# renders it. {} until a server connects.
var _reported_lsp_status: Dictionary = {}

# Injected seams (wired once by mcp_server._init_lsp_publisher). Keep the
# lsp_status_changed signal + the transport on the orchestrator — this child does not
# own either.
# _on_status_changed: func() -> void — the orchestrator re-emits lsp_status_changed
#   when the reported verdict changes (the dock binds that signal on the server).
var _on_status_changed: Callable = Callable()
# _bound_port_provider: func() -> int — the live bound WS port (the transport owns it;
#   the watch needs it to skip re-publishing before/after the server is listening,
#   exactly as the pre-extraction watch read _transport.get_bound_port()).
var _bound_port_provider: Callable = Callable()


## The GDScript LSP endpoint THIS editor's setting points at (default
## 127.0.0.1:6005). A --lsp-port override is invisible here — the engine consumes
## it before OS.get_cmdline_args() and never writes it to the setting — so that
## case rides GODOT_MCP_LSP_PORT on the server (see docs/multi-instance.md).
## Static + editor-only (names EditorInterface); the registry callers pass the
## result into register()/ensure_registered() so registry_client.gd stays
## editor-clean for the Mode-B runtime autoload.
static func resolve_lsp_endpoint() -> Dictionary:
	var host := "127.0.0.1"
	var port := 6005
	var es := EditorInterface.get_editor_settings()
	if es != null:
		if es.has_setting("network/language_server/remote_host"):
			host = str(es.get_setting("network/language_server/remote_host"))
		if es.has_setting("network/language_server/remote_port"):
			port = int(es.get_setting("network/language_server/remote_port"))
	return {"host": host, "port": port}


## Wire the orchestrator's lsp_status_changed re-emit. Call once at construction,
## before any reported status arrives.
func set_status_changed_handler(on_status_changed: Callable) -> void:
	_on_status_changed = on_status_changed


## Wire the live bound-WS-port source (the transport owns the port; this child does
## not). Call once at construction, before connect_settings_watch / any re-publish.
func set_bound_port_provider(bound_port_provider: Callable) -> void:
	_bound_port_provider = bound_port_provider


## The MCP server reports the authoritative LSP verdict here — it can do reliable
## cross-process liveness (process.kill) and the real connection/root-verify, which
## the editor cannot (no engine API for its own LSP bind status). The dock renders
## whatever was last reported. Keys: state ("active"/"conflict"/"unavailable"), host,
## port, detail. Empty until an MCP server connects. Notifies the orchestrator so it
## re-emits lsp_status_changed (the signal stays on the server for the dock).
func set_reported_lsp_status(status: Dictionary) -> void:
	_reported_lsp_status = status.duplicate()
	if _on_status_changed.is_valid():
		_on_status_changed.call()


func get_reported_lsp_status() -> Dictionary:
	return _reported_lsp_status


## Re-publish the registry entry when the editor's GDScript LSP port/host
## setting changes mid-session, so the published endpoint never goes stale.
## EditorSettings.settings_changed fires globally; we debounce by comparing the
## re-resolved endpoint against the last published one. Connected from start(),
## disconnected in stop() (I12 symmetry).
func connect_settings_watch() -> void:
	var lsp := resolve_lsp_endpoint()
	_last_lsp_host = lsp["host"]
	_last_lsp_port = lsp["port"]
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_signal("settings_changed") \
			and not es.settings_changed.is_connected(_on_editor_settings_changed):
		es.settings_changed.connect(_on_editor_settings_changed)


func disconnect_settings_watch() -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_signal("settings_changed") \
			and es.settings_changed.is_connected(_on_editor_settings_changed):
		es.settings_changed.disconnect(_on_editor_settings_changed)


func _on_editor_settings_changed() -> void:
	var bound_port: int = _bound_port_provider.call() if _bound_port_provider.is_valid() else -1
	if bound_port <= 0:
		return
	var lsp := resolve_lsp_endpoint()
	if lsp["host"] == _last_lsp_host and lsp["port"] == _last_lsp_port:
		return  # LSP endpoint unchanged — ignore unrelated editor-setting churn.
	_last_lsp_host = lsp["host"]
	_last_lsp_port = lsp["port"]
	RegistryClient.ensure_registered(bound_port, MCPAuth.get_published_token_path(), lsp["host"], lsp["port"])
	print("[MCPServer] LSP endpoint changed -> re-published %s:%d" % [lsp["host"], lsp["port"]])
