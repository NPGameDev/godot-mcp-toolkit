@tool
extends RefCounted
## Export-clean log helpers — ANSI stripping, log-level detection, and file-logging
## detection. Pure static utilities (RegEx + string ops + ProjectSettings/OS reads)
## with NO editor-only symbols, so this module is safe to preload from the runtime
## autoload's dependency closure (an editor-only name anywhere in that closure would
## parse-fail the autoload in an export — godotengine/godot#91713).
## @tool is REQUIRED so the `_ansi_re` static-var initializer
## runs in the editor: editor-side log tools call strip_ansi, and non-@tool scripts skip
## static initialization in the editor (the regex would be null → "Cannot call method
## 'sub' on a null value"). @tool names no editor symbols, so this stays export-clean —
## the annotation is ignored in export templates (silent-if-shipped is preserved).


# -- ANSI stripping ------------------------------------------------------------


## Compiled once at script load — one allocation per session.
## CSI sequences: ESC [ <params> <final>  (e.g. ESC[90m, ESC[0m)
## Simple escapes: ESC <letter>            (e.g. ESC c)
static var _ansi_re: RegEx = _compile_ansi_re()

static func _compile_ansi_re() -> RegEx:
	var re := RegEx.new()
	re.compile("\\x1b(?:\\[[0-9;]*[A-Za-z]|[A-Za-z])")
	return re


## Strip ANSI/VT100 escape sequences from a string.
## In headless mode Godot emits ANSI color codes in progress-bar and
## status messages. These contain raw ESC (0x1B) bytes that Godot's
## JSON.stringify() does not escape, producing invalid JSON and causing
## the TypeScript bridge to silently drop responses.
static func strip_ansi(text: String) -> String:
	return _ansi_re.sub(text, "", true)


# -- Log level detection -------------------------------------------------------


static func detect_log_level(line: String) -> String:
	if line.begins_with("ERROR:") or line.begins_with("USER ERROR:") \
			or line.begins_with("SCRIPT ERROR:") or line.begins_with("SHADER ERROR:"):
		return "error"
	if line.begins_with("WARNING:") or line.begins_with("USER WARNING:") \
			or line.begins_with("SCRIPT WARNING:"):
		return "warning"
	return "info"


## True for a Godot error-location continuation line — the indented "   at: …" line
## that follows an ERROR:/WARNING:/SCRIPT ERROR: message (and any leading-whitespace
## continuation). Used so a multi-line error is leveled as a unit: the file-tail buffer
## makes such a line inherit the preceding error/warning level (log_buffer.gd), and the
## source=file reader coalesces it into the prior entry (editor_commands.gd). Pass a RAW
## (un-edge-stripped) line so the leading whitespace is still visible.
static func is_continuation_line(line: String) -> bool:
	if line.begins_with(" ") or line.begins_with("\t"):
		return true
	return line.strip_edges().begins_with("at:")


# -- File logging detection ----------------------------------------------------


## Check whether file logging is enabled, including platform-specific overrides.
## ProjectSettings.get_setting() returns the base value; platform overrides
## (e.g. debug/file_logging/enable_file_logging.windows) are separate keys.
static func is_file_logging_enabled() -> bool:
	var key := "debug/file_logging/enable_file_logging"
	if ProjectSettings.get_setting(key, false):
		return true
	for tag in ["pc", "windows", "linuxbsd", "macos", "android", "ios", "web"]:
		if OS.has_feature(tag):
			var override_key: String = key + "." + tag
			if ProjectSettings.has_setting(override_key) \
					and ProjectSettings.get_setting(override_key, false):
				return true
	return false


# -- Log file path resolution --------------------------------------------------


## The configured engine log file, raw (un-globalized): the value of the
## debug/file_logging/log_path project setting, or the engine default
## user://logs/godot.log. Callers that dir-scan (the console file source) or
## surface the path in a response (the runtime debugger.get_log reader) use this
## so they stay in user:// space and their default-case output is byte-unchanged;
## callers that open the file and want a stable absolute path use resolve_log_path().
static func configured_log_path() -> String:
	return ProjectSettings.get_setting(
		"debug/file_logging/log_path", "user://logs/godot.log") as String


## The configured engine log file as an absolute OS path: configured_log_path()
## with user://res:// globalized (absolute paths pass through). Used by the direct
## readers that want a stable absolute path immune to a mid-session user:// remap —
## the 4.2-4.4 buffer tail and the editor-side debugger.get_log reader.
static func resolve_log_path() -> String:
	var configured := configured_log_path()
	if configured.begins_with("user://") or configured.begins_with("res://"):
		return ProjectSettings.globalize_path(configured)
	return configured
