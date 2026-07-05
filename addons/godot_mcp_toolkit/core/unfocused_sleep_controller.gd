@tool
extends RefCounted
## Lowers / restores the machine-wide unfocused-sleep EditorSetting while an MCP
## client is connected, crash-safe via the first-writer-wins backup.
##
## When the editor loses focus, Godot's unfocused_low_processor_mode_sleep_usec
## (default ~100000 µs ≈ 10 fps) throttles _process. Since the server polls the
## WebSocket in _process, that slows MCP interactions to ~2-3 Hz — and the editor
## is normally UNFOCUSED during an MCP session (the user is on the chat), so this
## is the common case, not an edge. While an authenticated client is connected AND
## the user has opted in, this lowers the sleep to keep the editor responsive
## unfocused, then restores it on the last disconnect / stop.
##
## The key is a machine-wide EditorSetting (every project on this editor version),
## and set_setting only reaches disk on a later save() — so a crash (after a flush)
## or a concurrent second editor could strand it at the boosted value and, worse,
## re-read that as the "original" on the next launch, losing the true default. We
## guard against that with a machine-wide, version-keyed, first-writer-wins backup
## of the TRUE original (in the registry dir, under the registry lock) plus a
## conflict-aware restore and a startup self-heal. Opt-in + tunable rate live in
## EditorSettings (registered in plugin.gd::_register_editor_settings).
##
## Editor-side ONLY — and TAINTED by design: it drives EditorSettings (via the
## injected accessor) and the registry lock. That is allowed because the Mode-B
## runtime autoload has NO unfocused sleep and must NEVER preload this file. #91713
## therefore does not gate this child, but a runtime reference to it WOULD taint the
## autoload, so keep it strictly editor-only: only mcp_server.gd (the editor server)
## preloads it. The orchestrator owns the cross-subsystem TRIGGER points (first
## authed connect → lower; last disconnect → restore; start() → self-heal first);
## this child owns only the MECHANISM behind each.
##
## Seam the orchestrator injects (so this child is testable and the EditorInterface
## reach stays in the editor file, mirroring scene_lease's root-resolver): an
## EditorSettings accessor Callable. The pure backup/restore decision logic lives in
## unfocused_backup.gd (which this child calls directly, like the server did) and is
## headless-unit-tested there; this child only sequences those decisions against the
## live setting + the registry lock.

const RegistryClient := preload("res://addons/godot_mcp_toolkit/registry/registry_client.gd")
const _UnfocusedBackup := preload("res://addons/godot_mcp_toolkit/core/unfocused_backup.gd")

# The global EditorSetting we throttle, plus the two opt-in / rate keys (machine-wide).
const _UNFOCUSED_SLEEP_KEY := "interface/editor/unfocused_low_processor_mode_sleep_usec"
const _RESPONSIVE_ENABLED_KEY := "mcp_toolkit/performance/keep_editor_responsive_unfocused"
const _RESPONSIVE_SLEEP_KEY := "mcp_toolkit/performance/unfocused_responsive_sleep_usec"
# Default for the tunable EditorSetting unfocused_responsive_sleep_usec.
const _ACTIVE_UNFOCUSED_SLEEP_USEC := 16666  # ~= 60 fps while a client is connected

# Injected EditorSettings accessor: func() -> EditorSettings (or null in headless).
# The editor injects EditorInterface.get_editor_settings; a unit test injects a stub.
# This is the ONLY way this child reaches the editor — it never names EditorInterface,
# so the EditorInterface reach lives in the editor orchestrator (mirrors scene_lease).
var _settings_accessor: Callable = Callable()

# Best-effort in-memory mirror: >= 0 while THIS instance holds the boost active, -1
# otherwise. The machine-wide backup FILE is the source of truth for restore (this
# only gates whether the disconnect/stop path runs).
var _original_unfocused_sleep_usec: int = -1


## Wire the EditorSettings accessor. Call once at construction, before any boost.
func set_settings_accessor(settings_accessor: Callable) -> void:
	_settings_accessor = settings_accessor


## True when the user has opted in (default true). Missing/unavailable settings
## fall back to the default so behaviour is unchanged from before this iter.
func is_unfocused_responsive_enabled() -> bool:
	var es = _editor_settings()
	if es == null or not es.has_setting(_RESPONSIVE_ENABLED_KEY):
		return true
	return bool(es.get_setting(_RESPONSIVE_ENABLED_KEY))


## fps implied by the configured boosted value, for the dock indicator + log.
func get_unfocused_responsive_fps() -> int:
	var usec := _configured_responsive_usec()
	if usec <= 0:
		return 0
	return int(round(1_000_000.0 / float(usec)))


## True while THIS instance holds the boost active (best-effort; the backup file
## is authoritative for restore). Used by the dock's 3-state indicator.
func is_unfocused_boost_active() -> bool:
	return _original_unfocused_sleep_usec >= 0


## Apply or restore the boost immediately when the user flips the opt-in toggle,
## rather than only on the next connect/disconnect. authed_peer_count lets the
## orchestrator pass the live count (this child does not own the transport).
func notify_unfocused_responsive_setting_changed(authed_peer_count: int) -> void:
	if is_unfocused_responsive_enabled():
		if authed_peer_count > 0:
			lower()
	else:
		restore()


## Lower the global key to the boosted value on the FIRST authed connect (idempotent
## via should_capture_boost). Captures the TRUE original to the machine-wide backup
## under the registry lock first, so a concurrent instance can't record an
## already-boosted value as the original.
func lower() -> void:
	if not _UnfocusedBackup.should_capture_boost(
			is_unfocused_responsive_enabled(), is_unfocused_boost_active()):
		return
	var es = _editor_settings()
	if es == null:
		return
	var live := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var boosted := _configured_responsive_usec()
	# Machine-wide first-writer-wins backup of the TRUE original, under the
	# registry lock so a concurrent instance can't capture an already-boosted
	# value as the original.
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	RegistryClient.acquire_lock()
	_UnfocusedBackup.capture_if_absent(dir, live, boosted, ver)
	RegistryClient.release_lock()
	es.set_setting(_UNFOCUSED_SLEEP_KEY, boosted)
	_original_unfocused_sleep_usec = live
	print("[MCPServer] unfocused-responsive mode ON: %s %d -> %d (~%d fps while unfocused)" % [
		_UNFOCUSED_SLEEP_KEY, live, boosted, get_unfocused_responsive_fps()])


## Restore the global key on the LAST authed disconnect / stop. Conflict-aware: if a
## human or another tool changed the key during the boost, keep their value and just
## clear the backup.
func restore() -> void:
	if not is_unfocused_boost_active():
		return
	var es = _editor_settings()
	if es == null:
		_original_unfocused_sleep_usec = -1
		return
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	RegistryClient.acquire_lock()
	var backup := _UnfocusedBackup.read_backup(dir, ver)
	var current := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var decision := _UnfocusedBackup.resolve_restore(current, backup)
	if decision["restore"]:
		es.set_setting(_UNFOCUSED_SLEEP_KEY, int(decision["value"]))
	_UnfocusedBackup.delete_backup(dir, ver)
	RegistryClient.release_lock()
	_original_unfocused_sleep_usec = -1
	if decision["restore"]:
		print("[MCPServer] unfocused-responsive mode OFF: %s restored to %d" % [
			_UNFOCUSED_SLEEP_KEY, int(decision["value"])])
	else:
		print("[MCPServer] unfocused-responsive mode OFF: %s left at %d (changed during boost; backup cleared)" % [
			_UNFOCUSED_SLEEP_KEY, current])


## Startup self-heal: if a previous session (crash) or a concurrent instance left a
## backup behind, revert the global key conflict-aware and clear the backup so the
## boost can never persist without a live connection. Runs regardless of the opt-in
## setting (a leftover from when it was ON must be cleaned even after the user turns
## it OFF). Safe at start(): no peer can be authed yet, so authed_peer_count is 0.
func self_heal(authed_peer_count: int) -> void:
	var dir := RegistryClient.registry_dir()
	var ver := _UnfocusedBackup.version_key()
	if not _UnfocusedBackup.has_backup(dir, ver):
		return
	if authed_peer_count > 0:
		return  # defensive — never true at start() (transport not built yet / no authed peer)
	var es = _editor_settings()
	if es == null:
		return
	RegistryClient.acquire_lock()
	var backup := _UnfocusedBackup.read_backup(dir, ver)
	var current := int(es.get_setting(_UNFOCUSED_SLEEP_KEY))
	var decision := _UnfocusedBackup.resolve_restore(current, backup)
	if decision["restore"]:
		es.set_setting(_UNFOCUSED_SLEEP_KEY, int(decision["value"]))
	_UnfocusedBackup.delete_backup(dir, ver)
	RegistryClient.release_lock()
	if decision["restore"]:
		print("[MCPServer] unfocused-responsive self-heal: reverted leftover %s to %d (crash/concurrent leftover)" % [
			_UNFOCUSED_SLEEP_KEY, int(decision["value"])])
	else:
		print("[MCPServer] unfocused-responsive self-heal: %s changed since boost (now %d); kept it, cleared stale backup" % [
			_UNFOCUSED_SLEEP_KEY, current])


# Configured boosted sleep value in µs (default 16666 = 60 fps; not clamped).
func _configured_responsive_usec() -> int:
	var es = _editor_settings()
	if es == null or not es.has_setting(_RESPONSIVE_SLEEP_KEY):
		return _ACTIVE_UNFOCUSED_SLEEP_USEC
	return int(es.get_setting(_RESPONSIVE_SLEEP_KEY))


# Resolve the live EditorSettings via the injected accessor (null in headless / when
# unwired). Keeps the EditorInterface reach in the editor orchestrator.
func _editor_settings():
	if not _settings_accessor.is_valid():
		return null
	return _settings_accessor.call()
