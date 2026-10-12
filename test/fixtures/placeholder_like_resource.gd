extends Resource
## Test double for a script resource whose script is not @tool, as the editor
## holds it.
##
## The editor gives such a script a placeholder instance, whose set() stores each
## value as given instead of converting it to the property's declared type. The
## headless unit runner gives scripts a live instance, which converts, so this
## script declares its properties in _get_property_list() and stores raw values to
## stand in for the placeholder. It lives in a file, not as an inner class, because
## a resource saved to disk refers to its script by path.

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
	]


func _set(property: StringName, value: Variant) -> bool:
	if property in [&"price", &"weight", &"note"]:
		_values[property] = value
		return true
	return false


func _get(property: StringName) -> Variant:
	return _values.get(property)
