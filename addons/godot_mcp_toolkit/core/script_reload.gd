@tool
extends RefCounted
## Brings a script the editor has cached up to date with its file on disk, without
## ever applying a source that does not compile.
##
## A write to a [code].gd[/code] file leaves the cached [Script] holding its old source,
## so the nodes running it keep the old code until it is reloaded. A reload here
## follows three rules: never one of the toolkit's own scripts, never an unchanged one,
## never a source that does not compile.

# Direct preloads, not core/modules.gd: the aggregator preloads this file.
const FileGuard := preload("res://addons/godot_mcp_toolkit/security/file_guard.gd")
const GDScriptSource := preload("res://addons/godot_mcp_toolkit/core/gdscript_source.gd")


## Brings [param script] up to date with its file on disk. [code]ResourceLoader.load()[/code]
## hands back the cached script, which keeps the source it was first loaded with after the
## file changes, so every node running it would run the old code. This reloads it the way
## the script editor reloads a script changed outside it: the file's text becomes
## [code]source_code[/code] and [code]reload(true)[/code] recompiles the cached object in
## place, which also updates the instances already running it. Unlike a
## [code]CACHE_MODE_IGNORE[/code] load, it never goes through the resource loader.
##
## Nothing happens unless [method should_reload_script] agrees and the script is a
## [GDScript]. A file that does not compile is never applied: the cached script stays as
## it was, so its nodes keep working, and the outcome says why. [param judged_valid_source]
## is a source the caller has already judged valid; while the file still holds exactly that
## text, the compile check is not run a second time. If the reload itself fails, the
## script goes back to its previous source and recompiles it.
##
## Returns [code]{reloaded: bool, compile_error: String, previous_kept: bool}[/code].
## [code]compile_error[/code] is "" unless the file's source was refused or the reload
## itself failed. [code]previous_kept[/code] is false only when a failed reload could not
## recompile the previous source either, so the script may have no working code.
static func reload_script_from_disk(script: Script, judged_valid_source: String = "") -> Dictionary:
	var outcome := unreloaded_outcome()
	if not (script is GDScript):
		return outcome
	var script_path := script.resource_path
	var disk_source := FileAccess.get_file_as_string(script_path)
	if not should_reload_script(script_path, disk_source, script.source_code):
		return outcome
	if disk_source != judged_valid_source:
		var verdict := GDScriptSource.judge(disk_source, script_path)
		if not bool(verdict["valid"]):
			var conflict := str(verdict["conflict"])
			outcome["compile_error"] = conflict if conflict != "" else "the source on disk does not compile"
			return outcome
	var previous_source := script.source_code
	script.source_code = disk_source
	var reload_error := script.reload(true)
	if reload_error != OK:
		# A failed reload marks the script invalid, and on 4.3+ its nodes then stop running
		# any of it. Recompiling the previous source brings that code back, and keeping it
		# as the source makes the next call see the file as changed and try again.
		script.source_code = previous_source
		var restore_error := script.reload(true)
		outcome["compile_error"] = "the reload failed (%s)" % error_string(reload_error)
		if restore_error != OK:
			outcome["compile_error"] += " and the previous version could not be restored"
			outcome["previous_kept"] = false
		return outcome
	outcome["reloaded"] = true
	return outcome


## [method reload_script_from_disk] for the script the editor has cached for
## [param file_path], after a write to that file. A file the editor has not loaded is left
## alone: its first load reads the file anyway. So is a cached resource that is not a
## script, such as a shader.
## Returns the same [code]{reloaded, compile_error, previous_kept}[/code] outcome.
static func reload_cached_script(file_path: String, judged_valid_source: String = "") -> Dictionary:
	if not ResourceLoader.has_cached(file_path):
		return unreloaded_outcome()
	var cached: Resource = ResourceLoader.load(file_path)
	if not (cached is Script):
		return unreloaded_outcome()
	return reload_script_from_disk(cached, judged_valid_source)


## Whether a cached script at [param script_path] should take [param disk_source]: the
## file has text, the text differs from [param cached_source], and the script is not one
## of the toolkit's own. A reload is skipped when nothing changed because it cancels any
## coroutine suspended in the script. Pure, so it can be unit-tested.
static func should_reload_script(script_path: String, disk_source: String, cached_source: String) -> bool:
	if FileGuard.is_toolkit_source(script_path):
		return false
	return not disk_source.is_empty() and disk_source != cached_source


## The [method reload_script_from_disk] outcome of a call that left the script as it was:
## [code]{reloaded: false, compile_error: "", previous_kept: true}[/code].
static func unreloaded_outcome() -> Dictionary:
	return {"reloaded": false, "compile_error": "", "previous_kept": true}
