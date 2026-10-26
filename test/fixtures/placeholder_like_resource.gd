extends Resource
## Test double for a script resource whose script is not @tool, as the editor
## holds it.
##
## The editor gives such a script a placeholder instance, whose set() stores each
## value as given instead of converting it to the property's declared type. The
## headless unit runner gives scripts a live instance, which converts, so this
## script declares its properties in _get_property_list() and stores raw values to
## stand in for the placeholder. It lives in a file, not as an inner class, because
## a resource saved to disk refers to its script by path. Like a placeholder, it
## returns the typed default of its typed array [code]tags[/code] until it is set,
## and it stores a String given for its [Texture2D] property [code]icon[/code] as
## given. [code]icon_path[/code] is a String property that holds a file path.

var _values := {}


func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "price", "type": TYPE_INT, "usage": PROPERTY_USAGE_DEFAULT},
		{"name": "weight", "type": TYPE_FLOAT, "usage": PROPERTY_USAGE_DEFAULT},
		{
			"name": "note",
			"type": TYPE_NIL,
			"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_NIL_IS_VARIANT,
		},
		{
			"name": "tags",
			"type": TYPE_ARRAY,
			"hint": PROPERTY_HINT_ARRAY_TYPE,
			"hint_string": "String",
			"usage": PROPERTY_USAGE_DEFAULT,
		},
		{
			"name": "icon",
			"type": TYPE_OBJECT,
			"hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Texture2D",
			"usage": PROPERTY_USAGE_DEFAULT,
		},
		{
			"name": "icon_path",
			"type": TYPE_STRING,
			"hint": PROPERTY_HINT_FILE,
			"usage": PROPERTY_USAGE_DEFAULT,
		},
	]


func _set(property: StringName, value: Variant) -> bool:
	if property in [&"price", &"weight", &"note", &"tags", &"icon", &"icon_path"]:
		_values[property] = value
		return true
	return false


func _get(property: StringName) -> Variant:
	if property == &"tags" and not _values.has(property):
		var tags: Array[String] = []
		return tags
	return _values.get(property)
