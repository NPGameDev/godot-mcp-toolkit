@tool
extends RefCounted
## Untrusted-content envelope wrapper.
##
## Wraps user-authored / project-authored content in a nonce-tagged
## <untrusted-{nonce}> envelope before it is returned to the LLM.
## Scrubs existing envelope tags from the body to prevent tag-breakout
## injection. Never applied to write paths or binary (screenshot) data.

## Compiled once at script load — one allocation per editor session.
static var _envelope_tag_re: RegEx = _compile_envelope_re()

static func _compile_envelope_re() -> RegEx:
	var re := RegEx.new()
	re.compile("(?i)<\\s*/?\\s*untrusted(?:-[0-9a-f]*)?(?:\\s[^>]*)?>")
	return re


static func wrap(kind: String, source: String, body: String) -> String:
	var nonce := "%08x" % randi()
	var scrubbed := _scrub_envelope_tags(body)
	return '<untrusted-%s kind="%s" source="%s">\n%s\n</untrusted-%s>' % [nonce, kind, source, scrubbed, nonce]


static func _scrub_envelope_tags(text: String) -> String:
	return _envelope_tag_re.sub(text, "[scrubbed-envelope-tag]", true)
