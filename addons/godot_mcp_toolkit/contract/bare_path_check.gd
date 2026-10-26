@tool
extends RefCounted
## Decides whether a property write gives a bare path, and words its refusal.
##
## A bare path is a String given where the property declares a Resource. The node,
## scene and resource writers each take this one message and end it with their own
## outcome, so the three describe a bare path alike.


## The message for a bare path: a String [param raw_value] written to
## [param property_name], whose declared type [param declared_type] is an Object.
## A writer never binds a bare path: a live instance drops it and the editor's
## placeholder for a script that is not [code]@tool[/code] stores the String, which
## then reaches the saved file.
## [br][br]
## A [code]res://[/code] path gets the tagged form with the same path. A
## [code]uid://[/code] path gets the tagged form with the path the UID names, since
## the tagged form takes only a [code]res://[/code] path, or says that no resource
## has that UID. A [code]user://[/code] path is refused: only a project resource can
## be bound.
## [br][br]
## Returns the message without its closing punctuation, so each writer ends it with
## its own outcome, or [code]""[/code] when [param raw_value] is not a bare path.
static func bare_path_message(
	property_name: String, raw_value: Variant, declared_type: int,
) -> String:
	if declared_type != TYPE_OBJECT or typeof(raw_value) != TYPE_STRING:
		return ""
	var path := str(raw_value)
	var expects := "property '%s' expects a Resource, not a bare string path" % property_name
	if path.begins_with("res://"):
		return "%s. %s" % [expects, _tagged_form_hint(path)]
	if path.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(path)
		if uid == ResourceUID.INVALID_ID or not ResourceUID.has_id(uid):
			return "%s, and no resource has the UID %s" % [expects, path]
		return "%s. %s" % [expects, _tagged_form_hint(ResourceUID.get_id_path(uid))]
	if path.begins_with("user://"):
		return "%s, and only a res:// resource can be bound, not a user:// file" % expects
	return ""


static func _tagged_form_hint(resource_path: String) -> String:
	return "Use {\"type\": \"Resource\", \"path\": \"%s\"} as the value" % resource_path
