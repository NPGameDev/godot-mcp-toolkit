@tool
extends RefCounted
## Untrusted-content envelope wrapper (I5).
##
## Wraps user-authored / project-authored content in an <untrusted>
## envelope before it is returned to the LLM. Never applied to write
## paths or binary (screenshot) data.


static func wrap(kind: String, source: String, body: String) -> String:
	return '<untrusted kind="%s" source="%s">\n%s\n</untrusted>' % [kind, source, body]
