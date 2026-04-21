@tool
extends RefCounted
## Untrusted-content envelope wrapper.
##
## Wraps user-authored / project-authored content in a nonce-tagged
## <untrusted-{nonce}> envelope before it is returned to the LLM.
## Scrubs existing envelope tags from the body to prevent tag-breakout
## injection. Never applied to write paths or binary (screenshot) data.

## Compiled lazily on first use — one allocation per editor session.
static var _envelope_tag_re: RegEx


static func wrap(kind: String, source: String, body: String) -> String:
	var nonce := "%08x" % randi()
	var scrubbed := _scrub_envelope_tags(body)
	return '<untrusted-%s kind="%s" source="%s">\n%s\n</untrusted-%s>' % [nonce, kind, source, scrubbed, nonce]


static func _scrub_envelope_tags(text: String) -> String:
	if _envelope_tag_re == null:
		_envelope_tag_re = RegEx.new()
		_envelope_tag_re.compile("(?i)<\\s*/?\\s*untrusted(?:-[0-9a-f]*)?(?:\\s[^>]*)?>")
	return _envelope_tag_re.sub(text, "[scrubbed-envelope-tag]", true)
