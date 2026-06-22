@tool
extends RefCounted
## Secret scrubber — redacts credentials from log/error output before
## returning it through the MCP transport. Applied to debugger_get_log
## and editor_get_console; never applied to
## script_read (source code should not be mutated).

# Three high-precision patterns that cover real secrets with minimal
# false-positives. The broad hex pattern ([A-Fa-f0-9]{32,}) is
# deliberately omitted — false-positives on Godot UIDs, asset hashes,
# and import checksums outweigh the marginal secret-detection gain.
# Add patterns here only when a concrete leak is found.
const PATTERNS: Array[String] = [
	"(?i)(api[_-]?key|token|secret|password)\\s*[:=]\\s*[\\w\\.\\-]+",
	"sk-[A-Za-z0-9]{20,}",
	"(?i)bearer\\s+[A-Za-z0-9\\.\\-_]+",
]


## Compiled once at script load.
static var _compiled_patterns: Array[RegEx] = _compile_patterns()

static func _compile_patterns() -> Array[RegEx]:
	var out: Array[RegEx] = []
	for pattern in PATTERNS:
		var regex := RegEx.new()
		regex.compile(pattern)
		out.append(regex)
	return out


## Scrub secrets from text. Returns {text: String, redaction_count: int}.
## When redaction_count > 0 and source is non-empty, emits a push_warning
## so developers can correlate [REDACTED] appearances with the scrubber.
static func scrub(text: String, source: String = "") -> Dictionary:
	var out := text
	var redaction_count := 0
	for regex in _compiled_patterns:
		var matches := regex.search_all(out)
		redaction_count += matches.size()
		out = regex.sub(out, "[REDACTED]", true)
	if redaction_count > 0 and not source.is_empty():
		push_warning("[Scrubber] %d redactions applied to %s" % [redaction_count, source])
	return {"text": out, "redaction_count": redaction_count}
