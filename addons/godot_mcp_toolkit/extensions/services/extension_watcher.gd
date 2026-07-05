@tool
extends RefCounted
## Tracks the live extension set and reconciles it with editor filesystem /
## settings changes — the hot-reload aggregate.
##
## After startup discovery hands off, this persistent instance reacts to
## EditorFileSystem.filesystem_changed / ProjectSettings.settings_changed: on each
## debounced (500ms) scan it diffs the global class list against its known state
## (add / remove / modify / retry-previously-failed), applies the deltas to the
## live registry, and broadcasts an "extensions.changed" notification to all
## connected MCP bridges. It also serves extensions.refresh (a caller-forced
## rescan), registered against its own cmd_refresh in setup().
##
## The six state dictionaries below are this aggregate's internals, kept mutually
## consistent across one _do_rescan (a removed class is erased from all of them in
## lockstep). Nothing outside this module pokes them.

const _Support := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")
const _MetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")

# Retain references to C# extension instances loaded during hot-reload to prevent
# GC from invalidating registered Callables (the startup pass retains its own via
# the registry meta — see extension_discovery.gd).
var _instances: Array = []
var _registry: MCPToolkitCommandRegistry = null
var _server: Node = null
var _known_extensions: Dictionary = {}      # class_name_str -> script_path
var _class_methods: Dictionary = {}         # class_name_str -> Array[String] (methods)
var _class_metadata: Dictionary = {}        # class_name_str -> Dictionary (method -> str(meta))
var _failed_classes: Dictionary = {}        # class_name_str -> true (failed validation, retry on scan)
var _debounce_pending := false

# class_name_str -> hash of the extension's source file at the moment it was last
# loaded into the live registry. Used ONLY on Godot 4.2 to detect an in-session
# edit to an existing extension that the 4.2 cache path (CACHE_MODE_REUSE) cannot
# apply live, so extensions.refresh can nudge the caller to restart the editor.
var _class_source_fingerprint: Dictionary = {}
# class_name_str -> script_path for extensions whose source changed on disk but
# could not be re-applied in-session on Godot 4.2 (restart needed). Drained by
# cmd_refresh into a response hint.
var _pending_restart_modifies: Dictionary = {}


## Wire this watcher to the live registry + server and arm it: snapshot the current
## extension classes, rebuild the class->methods map, connect the EditorFileSystem
## and ProjectSettings signals, and register extensions.refresh against cmd_refresh.
## The caller MUST retain this instance (prevents GC; it owns the live state and the
## signal connections the composer later disconnects).
func setup(registry: MCPToolkitCommandRegistry, server: Node) -> void:
	_registry = registry
	_server = server
	# Snapshot current extension classes.
	_snapshot_current_extensions()
	# Build class->methods map from already-registered extension methods.
	_rebuild_class_methods_map()
	# Connect to EditorFileSystem.
	var efs := EditorInterface.get_resource_filesystem()
	efs.filesystem_changed.connect(on_filesystem_changed)
	# Also rescan when project settings change (catches addon enable/disable toggles).
	ProjectSettings.settings_changed.connect(on_settings_changed)
	# Register extensions.refresh — allows LLMs / headless mode to force
	# a filesystem scan + extension re-discovery without editor focus.
	registry.add("extensions.refresh", func(params: Dictionary) -> Dictionary:
		return await cmd_refresh(params)
	, MCPToolkitCommandOptions.new()
		.with_description("Force a filesystem scan and re-discover extensions (use when files were created externally)")
		.mark_idempotent()
		.mark_scene_independent())
	print("[MCPExtensions] Hot-reload watcher active")


func _snapshot_current_extensions() -> void:
	_known_extensions.clear()
	var classes: Array = ProjectSettings.get_global_class_list()
	for entry in classes:
		if not _Support.is_extension_candidate(entry):
			continue
		if not _Support.is_addon_enabled(entry.get("path", "")):
			continue
		_known_extensions[entry.get("class", "")] = entry.get("path", "")


func _rebuild_class_methods_map() -> void:
	## Build class_name -> methods + metadata mapping from the registry's extension methods.
	## Called once at watcher start. During live reload, new methods are tracked
	## incrementally in _load_extension_tracked().
	_class_methods.clear()
	_class_metadata.clear()
	_class_source_fingerprint.clear()
	var all_ext_methods := _registry.get_extension_methods()
	# We can't perfectly attribute methods to classes after the fact, so we
	# re-scan: for each known class, load its script and call Register on a
	# temporary registry to capture which methods it adds.
	for cn: String in _known_extensions:
		var sp: String = _known_extensions[cn]
		# Baseline the on-disk source fingerprint so a later in-session edit is
		# detectable (drives the Godot 4.2 restart nudge; harmless on 4.3+).
		_class_source_fingerprint[cn] = _Support.hash_extension_source(sp)
		var probe := _Support.probe_extension(cn, sp, _server)
		var methods: Array = probe["methods"]
		if not methods.is_empty():
			_class_methods[cn] = methods
			_class_metadata[cn] = probe["metadata"]


## Force a filesystem scan and immediate extension re-discovery. Registered as the
## extensions.refresh handler in setup() — it mutates (drives a rescan) and returns
## the refreshed list, an acknowledged CQS exception (one round-trip for the caller).
func cmd_refresh(_params: Dictionary) -> Dictionary:
	## Uses scan() (not scan_sources()) so NEW files are discovered —
	## scan_sources() only re-checks already-known resources.
	var efs := EditorInterface.get_resource_filesystem()

	if _Support.is_godot_42():
		# Godot 4.2: the lighter is_scanning() wait. The 4.3+ signal-wait below both
		# (a) widens the await window enough that the editor's @tool reimport races our
		# extension (re)load and natively crashes 4.2, and (b) has a bounded settle that
		# is unreliable for 4.2's in-memory class-list flush. Empirically this scan +
		# is_scanning() wait discovers new extensions immediately on 4.2.
		efs.scan()
		var deadline := Time.get_ticks_msec() + 5000
		while efs.is_scanning() and Time.get_ticks_msec() < deadline:
			await _server.get_tree().create_timer(0.1).timeout
	else:
		# Godot 4.3+: arm the global-class-flush barrier BEFORE scanning. is_scanning()
		# alone is NOT a safe barrier: EditorFileSystem clears `scanning` on its worker
		# thread at the END of the FS walk — BEFORE the main thread flushes the global
		# class list (store_global_class_list, inside _update_script_classes) and emits
		# script_classes_updated. A rescan gated only on is_scanning() therefore diffs a
		# STALE ProjectSettings.get_global_class_list() and misses NEW class_names —
		# observed as extensions_refresh returning "commands:[]" for a just-added extension.
		var classes_flushed := [false]
		var on_flush := func() -> void:
			classes_flushed[0] = true
		var has_flush_signal := efs.has_signal("script_classes_updated")
		if has_flush_signal:
			efs.script_classes_updated.connect(on_flush)
		efs.scan()
		# Phase 1 — wait out the FS walk via the canonical scan-idle guard.
		await MCPToolkitSafeSceneOps.wait_for_scan_idle()
		# Phase 2 — wait for the main-thread class-list flush, bounded. A no-change scan
		# never emits script_classes_updated, so settle briefly then proceed rather than
		# hang; the flag (armed pre-scan) also captures a flush from Phase 1.
		if has_flush_signal:
			var settle := Time.get_ticks_msec() + 750
			while not classes_flushed[0] and Time.get_ticks_msec() < settle:
				await _server.get_tree().create_timer(0.05).timeout
			if efs.script_classes_updated.is_connected(on_flush):
				efs.script_classes_updated.disconnect(on_flush)

	# Run rescan on the now-fresh class list (bypass debounce).
	_debounce_pending = false
	_do_rescan()
	# Return current extension list with full metadata (same shape as
	# extensions.list and extensions.changed — input_schema, annotations, etc.).
	var methods := _registry.get_extension_methods()
	var result: Array[Dictionary] = []
	var grouped_keywords: PackedStringArray = []
	for method: String in methods:
		var entry := _MetaCommands.build_command_entry(_registry, method)
		# Collect keywords for the activation hint (a refresh-local post-step on the
		# shared wire entry — read back from the entry the builder produced).
		for kw in entry.get("group", {}).get("keywords", []):
			if str(kw) not in grouped_keywords:
				grouped_keywords.append(str(kw))
		result.append(entry)
	var response := {"success": true, "refreshed": true, "commands": result}
	if not grouped_keywords.is_empty():
		response["hint"] = (
			"Some extension tools are in on-demand groups and need activation "
			+ "before use. Call discover_tools(request: '%s') to load them."
		) % ", ".join(grouped_keywords)
	# Godot 4.2: surface in-session edits that couldn't be applied live (their updated
	# tools are absent from `commands` above) so the caller knows to restart the editor.
	if not _pending_restart_modifies.is_empty():
		var modified_names: PackedStringArray = []
		for cn: String in _pending_restart_modifies:
			modified_names.append(cn)
		var restart_hint := (
			"Godot 4.2: extension(s) [%s] were modified on disk but in-session changes "
			+ "can't be applied — restart the editor to load the updated version. "
			+ "(New/removed extensions apply live; Godot 4.3+ applies modifications live too.)"
		) % ", ".join(modified_names)
		response["hint"] = (str(response["hint"]) + " " + restart_hint) if response.has("hint") else restart_hint
	return response


func on_filesystem_changed() -> void:
	_schedule_rescan()


func on_settings_changed() -> void:
	# Don't rescan if the toolkit itself is being disabled — avoids race
	# conditions during teardown.
	if not EditorInterface.is_plugin_enabled("godot_mcp_toolkit"):
		return
	_schedule_rescan()


func _schedule_rescan() -> void:
	if _debounce_pending:
		return
	_debounce_pending = true
	# Use a SceneTree timer for debounce (500ms). The watcher is a RefCounted
	# so it can't own timers directly — the server node's tree provides them.
	_server.get_tree().create_timer(0.5).timeout.connect(_do_rescan)


## Pure set-diff kernel: classify the freshly-scanned class set against the
## watcher's known + previously-failed state, with no script loads and no global
## state — every input is passed in, so it is headless-unit-testable. Returns
## {"added": Dictionary, "removed": Array[String], "retry": Dictionary}:
##   added   = classes in `current` not in `known`           (class_name -> path)
##   removed = classes in `known` not in `current`           (class_name list)
##   retry   = previously-failed classes now present and NOT newly-added.
## `retry` is computed against `added`, so `added` is built first below.
static func compute_class_diff(current: Dictionary, known: Dictionary, failed: Dictionary) -> Dictionary:
	var added: Dictionary = {}     # class_name -> path
	var removed: Array[String] = []
	for cn: String in current:
		if cn not in known:
			added[cn] = current[cn]
	for cn: String in known:
		if cn not in current:
			removed.append(cn)

	# Retry previously-failed classes (script was fixed since last scan).
	var retry: Dictionary = {}
	for cn: String in failed:
		if cn in current and cn not in added:
			retry[cn] = current[cn]

	return {"added": added, "removed": removed, "retry": retry}


## Compute-phase: scan the live class list and classify it against known state,
## WITHOUT mutating the registry or the watcher's tracking dicts (the one
## exception is _pending_restart_modifies, the 4.2 restart-nudge ledger, which is
## a probe artifact, not registry state). Returns a delta dict carrying
## everything _apply_delta needs: {current, added, removed, retry, modified}.
func _compute_delta() -> Dictionary:
	var current: Dictionary = {}
	var classes: Array = ProjectSettings.get_global_class_list()
	for entry in classes:
		if not _Support.is_extension_candidate(entry):
			continue
		if not _Support.is_addon_enabled(entry.get("path", "")):
			continue
		current[entry.get("class", "")] = entry.get("path", "")

	# Pure add/remove/retry diff against known state.
	var diff := compute_class_diff(current, _known_extensions, _failed_classes)
	var added_classes: Dictionary = diff["added"]
	var removed_classes: Array[String] = diff["removed"]
	var retry_classes: Dictionary = diff["retry"]

	# Detect content changes in existing extensions (tools added/removed/modified
	# within the same class). Re-probe each known class and compare method lists
	# AND metadata (annotations, description, schema, timeout).
	var modified_classes: Dictionary = {}  # class_name -> path
	for cn: String in current:
		if cn in added_classes or cn in retry_classes:
			continue
		if not _class_methods.has(cn):
			continue
		var sp: String = current[cn]
		var probe := _Support.probe_extension(cn, sp, _server)
		var fresh_methods: Array = probe["methods"]
		var old_methods: Array = _class_methods.get(cn, [])
		var fresh_meta: Dictionary = probe["metadata"]
		var old_meta: Dictionary = _class_metadata.get(cn, {})
		if not _Support.arrays_equal(fresh_methods, old_methods) or fresh_meta != old_meta:
			modified_classes[cn] = sp

	# Godot 4.2 only: detect an in-session edit to an existing extension that the 4.2
	# cache path (CACHE_MODE_REUSE) can't apply live — the modified-detection probe above
	# reads the cached pre-edit script, so the change is invisible there. Compare the
	# on-disk source fingerprint instead and queue a one-time restart nudge.
	if _Support.is_godot_42():
		for cn: String in current:
			if cn in added_classes or cn in retry_classes or not _class_source_fingerprint.has(cn):
				continue
			if _Support.hash_extension_source(current[cn]) != _class_source_fingerprint[cn]:
				if cn not in _pending_restart_modifies:
					push_warning("[MCPExtensions] '%s' was edited but in-session changes can't be applied on Godot 4.2 - restart the editor to load the updated version (Godot 4.3+ applies edits live)." % cn)
				_pending_restart_modifies[cn] = current[cn]
			else:
				# Fingerprint matches the loaded version again (e.g. the edit was reverted).
				_pending_restart_modifies.erase(cn)

	return {
		"current": current,
		"added": added_classes,
		"removed": removed_classes,
		"retry": retry_classes,
		"modified": modified_classes,
	}


## Apply-phase: mutate the live registry + watcher tracking dicts to match the
## computed delta — unregister removed/modified methods, (re)load added/retry/
## modified classes, adopt the new known set, then broadcast + log the change.
func _apply_delta(delta: Dictionary) -> void:
	var current: Dictionary = delta["current"]
	var added_classes: Dictionary = delta["added"]
	var removed_classes: Array[String] = delta["removed"]
	var retry_classes: Dictionary = delta["retry"]
	var modified_classes: Dictionary = delta["modified"]

	# Collect removed method names before modifying state.
	var removed_methods: Array[String] = []
	for cn: String in removed_classes:
		if _class_methods.has(cn):
			removed_methods.append_array(_class_methods[cn])
			_class_methods.erase(cn)
		_class_metadata.erase(cn)
		_failed_classes.erase(cn)
		_class_source_fingerprint.erase(cn)
		_pending_restart_modifies.erase(cn)

	# Handle modified extensions: unregister old methods, then re-load fresh.
	for cn: String in modified_classes:
		if _class_methods.has(cn):
			for method: String in _class_methods[cn]:
				_registry.remove(method)
				print("[MCPExtensions]   ~ %s (modified, re-registering)" % method)
			removed_methods.append_array(_class_methods[cn])
			_class_methods.erase(cn)
		_class_metadata.erase(cn)

	# Unregister removed methods from the live registry.
	for method: String in removed_methods:
		if _registry.has_command(method):
			_registry.remove(method)
			print("[MCPExtensions]   - %s (removed)" % method)

	# Register new extensions.
	for cn: String in added_classes:
		_load_extension_tracked(cn, added_classes[cn])

	# Retry previously-failed classes.
	for cn: String in retry_classes:
		_load_extension_tracked(cn, retry_classes[cn])

	# Re-load modified extensions.
	for cn: String in modified_classes:
		_load_extension_tracked(cn, modified_classes[cn])

	# Update known state.
	_known_extensions = current

	# Broadcast if anything changed.
	var total_changes := removed_methods.size()
	for cn: String in added_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()
	for cn: String in retry_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()
	for cn: String in modified_classes:
		if _class_methods.has(cn):
			total_changes += _class_methods[cn].size()

	if total_changes > 0:
		_broadcast_extensions_changed(removed_methods)
		var parts: Array[String] = []
		var add_count := 0
		for cn: String in added_classes:
			if _class_methods.has(cn):
				add_count += 1
		for cn: String in retry_classes:
			if _class_methods.has(cn):
				add_count += 1
		if add_count > 0:
			parts.append("+%d" % add_count)
		if not modified_classes.is_empty():
			parts.append("~%d" % modified_classes.size())
		if not removed_classes.is_empty():
			parts.append("-%d" % removed_classes.size())
		if not parts.is_empty():
			print("[MCPExtensions] Hot-reload: %s class(es) changed" % " ".join(parts))


func _do_rescan() -> void:
	_debounce_pending = false
	var delta := _compute_delta()
	# Nothing changed — skip the apply phase entirely (no registry mutation, no
	# broadcast). Mirrors the pre-split early return.
	if delta["added"].is_empty() and delta["removed"].is_empty() \
			and delta["retry"].is_empty() and delta["modified"].is_empty():
		return
	_apply_delta(delta)


func _load_extension_tracked(class_name_str: String, script_path: String) -> void:
	## Load and register a single extension, tracking its methods + metadata.
	var before: Array = _registry.get_all_methods()
	var instance := _Support.load_extension(class_name_str, script_path, _registry, _server)
	if instance != null:
		# Retain the instance (C# GC-safety) — load_extension no longer holds it.
		_instances.append(instance)
		var after: Array = _registry.get_all_methods()
		var new_methods: Array[String] = []
		var new_metadata: Dictionary = {}
		for method: String in after:
			if method not in before:
				new_methods.append(method)
				new_metadata[method] = str(_registry.get_command_metadata(method))
		_class_methods[class_name_str] = new_methods
		_class_metadata[class_name_str] = new_metadata
		_failed_classes.erase(class_name_str)
		# Record the source fingerprint we just loaded, and clear any pending
		# restart nudge (this version is now live).
		_class_source_fingerprint[class_name_str] = _Support.hash_extension_source(script_path)
		_pending_restart_modifies.erase(class_name_str)
	else:
		_failed_classes[class_name_str] = true


func _broadcast_extensions_changed(removed_methods: Array[String]) -> void:
	## Build the extensions.changed notification payload (same shape as
	## extensions.list response + removed array) and broadcast to all peers.
	var commands: Array[Dictionary] = []
	var methods := _registry.get_extension_methods()
	for method: String in methods:
		commands.append(_MetaCommands.build_command_entry(_registry, method))
	var params := {"commands": commands, "removed": removed_methods}
	_server.broadcast_notification("extensions.changed", params)
