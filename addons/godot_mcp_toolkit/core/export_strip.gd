@tool
extends EditorExportPlugin
## Auto-strips godot_mcp_toolkit addon files, GDScript extensions, and
## res://.mcp.json from exported builds. C# extensions compile into .NET
## assemblies and cannot be stripped per-class — see docs/extending.md.
## Registered by plugin.gd; prevents MCP code shipping in game PCKs.
##
## Binary-token script export modes (Godot 4.3+ default) compile addon/extension
## .gd to .gdc in the built-in EditorExportGDScript plugin BEFORE this strip runs,
## so those scripts ship as inert, orphaned .gdc. There is no safe in-addon strip
## (set_exclude_filter is unbound through 4.6 — godotengine/godot#4054); the leak
## is cosmetic (never loaded at runtime). We WARN, we do not strip.

# The runtime-autoload identity (name/path + key/value derivation) is owned by this
# shared leaf, so the null-for-bake here and the plugin's registration path can never
# drift — one home for the pair the export must null and restore.
const AutoloadIdentity := preload("res://addons/godot_mcp_toolkit/core/autoload_identity.gd")

const _ADDON_PREFIX := "res://addons/godot_mcp_toolkit/"
const _MCP_JSON_PATH := "res://.mcp.json"

# Single source of truth for "what is an extension" — must match
# extension_loader.gd's _is_extension_candidate() GDScript check: an extension
# is a DIRECT subclass of MCPToolkitExtension. Multi-level inheritance is
# intentionally unsupported (and such orphan files are harmless in builds), so
# the strip is deliberately single-level too.
const _EXTENSION_BASE := "MCPToolkitExtension"

# EditorExportPlatform.ExportMessageType.EXPORT_MESSAGE_WARNING. Hard-coded as the
# integer ordinal (stable across 4.2–4.6, verified in engine source) because the
# enum + add_message() are GDScript-bound only on 4.4+ — a static reference would
# parse-error on 4.2/4.3 even inside a dead branch. Delivery uses has_method()+call()
# for the same reason.
const _EXPORT_MESSAGE_WARNING := 2

# Built in _export_begin() from the global class list. Keys = res:// paths of
# GDScript extension files (direct subclasses of MCPToolkitExtension).
var _extension_strip_paths: Dictionary = {}

# Leak detection: observe which addon/extension files actually reach our
# _export_file. In a binary-token script mode the built-in EditorExportGDScript
# plugin consumes every .gd before our strip runs, so addon/extension SCRIPTS
# never reach us while addon NON-script files (plugin.cfg, .uid, icons) still do.
# That asymmetry tells us the scripts leaked as orphaned .gdc. Reset in
# _export_begin, read in _export_end. Version-agnostic — no preset read needed.
var _saw_addon_script: bool = false
var _saw_addon_nonscript: bool = false
var _seen_ext: Dictionary = {}  # extension res:// path → true (reached _export_file)


func _get_name() -> String:
	return "MCPExportStrip"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_extension_strip_paths = _compute_strip_paths(ProjectSettings.get_global_class_list())
	_saw_addon_script = false
	_saw_addon_nonscript = false
	_seen_ext = {}
	# Null each required autoload for the bake so it doesn't ship in the PCK; restored
	# in _export_end. Derived per-pair from the shared identity leaf.
	for entry in AutoloadIdentity.REQUIRED_AUTOLOADS:
		var key := AutoloadIdentity.settings_key(str(entry[0]))
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(_ADDON_PREFIX):
		# Track for leak detection: in binary modes only NON-script addon files
		# reach us (the built-in tokenizer eats the .gd first) — see _decide_warning.
		if path.ends_with(".gd"):
			_saw_addon_script = true
		else:
			_saw_addon_nonscript = true
		skip()
		return
	if path == _MCP_JSON_PATH:
		skip()
		return
	if _extension_strip_paths.has(path):
		_seen_ext[path] = true
		skip()
		return


func _export_end() -> void:
	# Unconditional restore — self-heals if a prior export crashed mid-bake.
	for entry in AutoloadIdentity.REQUIRED_AUTOLOADS:
		ProjectSettings.set_setting(
				AutoloadIdentity.settings_key(str(entry[0])),
				AutoloadIdentity.settings_value(str(entry[1])))
	# Warn (don't strip) if a binary-token script mode shipped addon/extension .gd
	# as orphaned .gdc. No safe in-addon strip exists; the leak is cosmetic.
	var decision := _decide_warning(_saw_addon_script, _saw_addon_nonscript, _extension_strip_paths, _seen_ext)
	if decision["warn"]:
		_emit_warning(str(decision["message"]))
	_extension_strip_paths.clear()
	_seen_ext.clear()


# Deliver the binary-token leak warning. get_export_platform()/add_message() are
# GDScript-bound only on 4.4+, so use has_method()+call() dynamic dispatch — a
# static reference would parse-error on 4.2/4.3 even in a dead branch. On 4.3 (and
# as a universal fallback) push_warning() surfaces it in the Output log instead of
# the export dialog. 4.2 never reaches here (no binary mode → scripts ship as text
# → they are seen and stripped, so _decide_warning returns warn=false).
func _emit_warning(message: String) -> void:
	if has_method("get_export_platform"):
		var platform = call("get_export_platform")
		if platform != null and platform.has_method("add_message"):
			platform.call("add_message", _EXPORT_MESSAGE_WARNING, "MCP Toolkit", message)
			return
	push_warning(message)


# ── Extension scan (pure; unit-tested in test/run_unit_tests.gd) ──────────
# Single-level by design — mirrors the loader's definition of an extension (a
# DIRECT subclass of MCPToolkitExtension). The engine flattens a path-based
# `extends "res://.../some_extension.gd"` to its named base, so direct
# subclasses written either way report base == MCPToolkitExtension and are
# caught. Multi-level chains (class two+ levels deep) are NOT extensions and
# ship as harmless orphans.
static func _compute_strip_paths(classes: Array) -> Dictionary:
	var strip := {}  # path → true
	for entry in classes:
		if entry.get("base", "") != _EXTENSION_BASE:
			continue
		var p: String = entry.get("path", "")
		if not p.is_empty() and p.ends_with(".gd"):
			strip[p] = true
	return strip


# ── Leak-warning decision (pure; unit-tested in test/run_unit_tests.gd) ───────
# Given what reached _export_file, decide whether a binary-token script mode
# leaked addon/extension scripts as orphaned .gdc, and compose the warning.
#   addon leaked  ⟺  addon non-script files were exported but no addon .gd was
#                    (a binary mode swallowed them). The non-script signal is the
#                    false-positive guard: if the user already excluded the
#                    addon, NO addon file reaches us → saw_addon_nonscript=false
#                    → no warning (excluding the addon is exactly what we advise).
#   ext leaked    =  extension paths computed in _export_begin that never reached
#                    _export_file. (A manually-excluded single extension also
#                    reads as "unseen" — documented caveat in docs/extending.md.)
# Returns {warn, addon_leaked, leaked_ext_count, message}.
static func _decide_warning(saw_addon_script: bool, saw_addon_nonscript: bool, extension_strip_paths: Dictionary, seen_ext: Dictionary) -> Dictionary:
	var addon_leaked := saw_addon_nonscript and not saw_addon_script
	var leaked_ext_paths: Array = []
	for p in extension_strip_paths:
		if not seen_ext.has(p):
			leaked_ext_paths.append(p)
	var leaked_ext := leaked_ext_paths.size()
	if not addon_leaked and leaked_ext == 0:
		return {"warn": false, "addon_leaked": false, "leaked_ext_count": 0, "leaked_ext_paths": [], "message": ""}
	var subject := ""
	if addon_leaked:
		subject = "the Godot MCP Toolkit addon's scripts"
	if leaked_ext > 0:
		if subject != "":
			subject += " and "
		subject += "%d extension script(s)" % leaked_ext
	# Exclude-filter recipe naming exactly what leaked, so the user can copy the
	# addon glob AND each specific extension path straight into the preset's filter.
	var filter_parts: PackedStringArray = []
	if addon_leaked:
		filter_parts.append("`res://addons/godot_mcp_toolkit/*`")
	if leaked_ext > 0:
		var quoted: PackedStringArray = []
		for p in leaked_ext_paths:
			quoted.append("`%s`" % str(p))
		filter_parts.append("the extension script(s) " + ", ".join(quoted))
	var message := (
		"Script Export Mode is binary tokens — %s ship as inert, orphaned `.gdc` " % subject
		+ "(never loaded at runtime; no effect on your game). For a clean strip, set "
		+ "Script Export Mode to \"Text\", or add %s to this preset's exclude filter." % " and ".join(filter_parts)
	)
	return {"warn": true, "addon_leaked": addon_leaked, "leaked_ext_count": leaked_ext, "leaked_ext_paths": leaked_ext_paths, "message": message}
