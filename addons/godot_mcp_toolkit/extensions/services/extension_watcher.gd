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
## The seven state dictionaries below are this aggregate's internals, kept mutually
## consistent across one _do_rescan (a removed class is erased from all of them in
## lockstep). Nothing outside this module pokes them.

const Modules := preload("res://addons/godot_mcp_toolkit/core/modules.gd")
const _Support := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_support.gd")
const _MetaCommands := preload("res://addons/godot_mcp_toolkit/extensions/services/extension_meta_commands.gd")

# The Godot 4.2 restart advice, worded once for the extensions.refresh hint and the
# editor warning. On 4.2.2 only an edit made outside script_write / script_edit (or
# to a C# extension) waits for a restart; on 4.2.0 and 4.2.1 every edit does.
const _RESTART_AFTER_OUTSIDE_EDIT := (
	"Godot 4.2 can't apply that in-session - restart the editor to load the updated version."
)
const _RESTART_AFTER_ANY_EDIT := (
	"can't apply an extension edit in-session - restart the editor to load the updated version."
)

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

# class_name_str -> hash of the source the live registry last loaded the extension
# from. When the source the loader reads moves on from it, the class registers again,
# so no registered Callable outlives a reload of the code that made it. On Godot 4.2,
# where the loader reads the editor's cached script (CACHE_MODE_REUSE), it also tells
# an edit that never reached that cache in-session, which extensions.refresh nudges the
# caller to restart for.
var _class_source_fingerprint: Dictionary = {}
# class_name_str -> script_path for Godot 4.2 extensions whose edit on disk waits for
# an editor restart. Drained by cmd_refresh into a response hint.
var _pending_restart_modifies: Dictionary = {}
# class_name_str -> script_path for Godot 4.2 extensions whose file on disk does not
# compile, so the loaded version stays and a restart would load the broken file.
# Drained by cmd_refresh into a response hint that asks for a fix.
var _pending_fix_modifies: Dictionary = {}


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
		# detectable (drives the re-registration after a reload and the Godot 4.2
		# restart and fix nudges).
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
	# Godot 4.2: surface edits that aren't live (their updated tools are absent from
	# `commands` above) and what each one waits for.
	var waiting_hint := unapplied_edit_hint(
			PackedStringArray(_pending_restart_modifies.keys()),
			PackedStringArray(_pending_fix_modifies.keys()),
			Modules.VersionUtils.in_place_reload_safe())
	if not waiting_hint.is_empty():
		response["hint"] = (str(response["hint"]) + " " + waiting_hint) if response.has("hint") else waiting_hint
	return response


## The extensions.refresh hint for Godot 4.2 extensions whose edit is not live:
## [param restart_names] wait for an editor restart, and [param fix_names] have a file
## that does not compile, which a restart would load broken. [param toolkit_writes_live]
## is false on Godot 4.2.0 and 4.2.1, where an edit made with script_write or script_edit
## waits for a restart too. Returns "" when both lists are empty. Pure, so it can be
## unit-tested.
static func unapplied_edit_hint(
		restart_names: PackedStringArray, fix_names: PackedStringArray, toolkit_writes_live: bool = true,
) -> String:
	var sentences: PackedStringArray = []
	if not restart_names.is_empty() and toolkit_writes_live:
		sentences.append((
			"Godot 4.2: extension(s) [%s] were edited outside script_write / script_edit, "
			+ "or are C#, and " + _RESTART_AFTER_OUTSIDE_EDIT + " (An edit made with "
			+ "script_write or script_edit applies live when it compiles; Godot 4.3+ applies "
			+ "every edit live.)"
		) % ", ".join(restart_names))
	elif not restart_names.is_empty():
		sentences.append((
			"Godot 4.2.0 and 4.2.1: extension(s) [%s] were edited, and these versions "
			+ _RESTART_AFTER_ANY_EDIT + " (Godot 4.2.2 applies an edit made with script_write "
			+ "or script_edit live when it compiles; Godot 4.3+ applies every edit live.)"
		) % ", ".join(restart_names))
	if not fix_names.is_empty():
		sentences.append((
			"Godot 4.2: the file(s) of extension(s) [%s] do not compile, so the editor keeps "
			+ "the version it loaded. Fix the file with script_write or script_edit "
			+ "(script_check lists its errors), then call extensions_refresh."
		) % ", ".join(fix_names))
	return " ".join(sentences)


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


## Whether a known extension registers again, given [param probe] (what
## [code]probe_extension[/code] reads now), the [param old_methods] and [param old_meta]
## it registered, and [param loaded_hash], the hash of the source it registered from. A
## change to its tools counts, and so does any change to the source the loader reads, a
## body-only edit included: the registered Callables were made by the code before the
## change, so they must not outlive it. A probe with no source hash (a C# extension)
## compares tools only. Pure, so it can be unit-tested.
static func needs_reregister(probe: Dictionary, old_methods: Array, old_meta: Dictionary, loaded_hash: int) -> bool:
	var fresh_methods: Array = probe.get("methods", [])
	var fresh_meta: Dictionary = probe.get("metadata", {})
	if not _Support.arrays_equal(fresh_methods, old_methods) or fresh_meta != old_meta:
		return true
	var probed_hash := int(probe.get("source_hash", 0))
	return probed_hash != 0 and probed_hash != loaded_hash


## Compute-phase: scan the live class list and classify it against known state,
## WITHOUT mutating the registry or the watcher's tracking dicts (the one
## exception is the 4.2 nudge ledger, _pending_restart_modifies and
## _pending_fix_modifies, which is a probe artifact, not registry state). Returns a
## delta dict carrying everything _apply_delta needs: {current, added, removed, retry,
## modified}.
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
	# AND metadata (annotations, description, schema, timeout), and the source the
	# loader reads (see needs_reregister).
	var modified_classes: Dictionary = {}  # class_name -> path
	for cn: String in current:
		if cn in added_classes or cn in retry_classes:
			continue
		if not _class_methods.has(cn):
			continue
		var sp: String = current[cn]
		var probe := _Support.probe_extension(cn, sp, _server)
		if needs_reregister(probe, _class_methods.get(cn, []), _class_metadata.get(cn, {}),
				int(_class_source_fingerprint.get(cn, 0))):
			modified_classes[cn] = sp

	# Godot 4.2 only: the probe above reads the editor's cached script (CACHE_MODE_REUSE),
	# so it sees an edit only once a toolkit write has reloaded that script (on 4.2.2; on
	# 4.2.0 and 4.2.1 the toolkit reloads nothing). Any other edit to an existing
	# extension waits for a restart, or for a fix when the file does not compile; queue a
	# one-time nudge for it.
	if _Support.is_godot_42():
		for cn: String in current:
			if cn in added_classes or cn in retry_classes or not _class_source_fingerprint.has(cn):
				continue
			_record_unapplied_edit(cn, current[cn],
					_Support.unapplied_edit(current[cn], _class_source_fingerprint[cn]))

	return {
		"current": current,
		"added": added_classes,
		"removed": removed_classes,
		"retry": retry_classes,
		"modified": modified_classes,
	}


# Files class_name_str in the 4.2 nudge ledger its unapplied_edit verdict picks, warning
# in the editor once when it first lands there.
func _record_unapplied_edit(class_name_str: String, script_path: String, verdict: int) -> void:
	var needs_restart := verdict == _Support.EDIT_NEEDS_RESTART
	var needs_fix := verdict == _Support.EDIT_NEEDS_FIX
	if needs_restart and class_name_str not in _pending_restart_modifies:
		if Modules.VersionUtils.in_place_reload_safe():
			push_warning((
				"[MCPExtensions] '%s' was edited outside script_write / script_edit, or is C#, and "
				+ _RESTART_AFTER_OUTSIDE_EDIT
			) % class_name_str)
		else:
			push_warning((
				"[MCPExtensions] '%s' was edited, and Godot 4.2.0 and 4.2.1 " + _RESTART_AFTER_ANY_EDIT
			) % class_name_str)
	if needs_fix and class_name_str not in _pending_fix_modifies:
		push_warning("[MCPExtensions] '%s' does not compile on disk, so the editor keeps the version it loaded - fix the file (script_check lists its errors)." % class_name_str)
	if needs_restart:
		_pending_restart_modifies[class_name_str] = script_path
	else:
		_pending_restart_modifies.erase(class_name_str)
	if needs_fix:
		_pending_fix_modifies[class_name_str] = script_path
	else:
		_pending_fix_modifies.erase(class_name_str)


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
		_pending_fix_modifies.erase(cn)

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
		# Record the source this version was loaded from. On 4.2 that is the cached
		# script, which can lag the file, so a nudge clears only once they match.
		var loaded_hash := _Support.loaded_source_hash(instance, script_path)
		_class_source_fingerprint[class_name_str] = loaded_hash
		if loaded_hash == _Support.hash_extension_source(script_path):
			_pending_restart_modifies.erase(class_name_str)
			_pending_fix_modifies.erase(class_name_str)
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
